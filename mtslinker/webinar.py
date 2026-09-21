import json
import logging
import os
import re
import shutil

from mtslinker.downloader import (
    construct_json_data_url,
    fetch_json_data,
    download_chunks_parallel,
    download_slide_images,
    combine_slides_to_pdf,
)
from mtslinker.processor import compile_final_video, process_and_download_clips
from mtslinker.utils import create_directory_if_not_exists
from mtslinker.timeline import StreamTimeline, AudioTrack
from mtslinker.prober import MediaProber
from mtslinker.ffmpeg import FFmpegRunner
from mtslinker.audio import AudioMerger


def fetch_webinar_data(event_sessions: str, record_id: str, session_id=None, max_duration=None):
    json_data_url = construct_json_data_url(event_session_id=event_sessions, recording_id=record_id)
    json_data = fetch_json_data(url=json_data_url, session_id=session_id)

    if not json_data:
        logging.error('Failed to fetch webinar data. Check the session ID or URL.')
        return

    sanitized_name = re.sub(r'[\s\/:*?"<>|]+', '_', json_data['name'])
    directory = create_directory_if_not_exists(sanitized_name)
    output_video_path = os.path.join(directory, f'{sanitized_name}.mp4')

    total_duration, chunks, slide_events, timeline = process_and_download_clips(directory, json_data)
    logging.info(f'Found {len(chunks)} chunks to download ({total_duration} sec total)')

    # Download all chunks in parallel
    downloaded_files = download_chunks_parallel(chunks, directory)
    logging.info(f'Downloaded {len(downloaded_files)} files, starting merge...')

    # Download presentation slides if any
    downloaded_slides = []
    if slide_events:
        downloaded_slides = download_slide_images(slide_events, directory)

    compile_final_video(
        total_duration, downloaded_files, directory, output_video_path,
        max_duration, slide_events=downloaded_slides, timeline=timeline,
    )
    logging.info(f'Final video saved to {output_video_path}')

    return 1


def _fetch_json_and_timeline(event_sessions: str, record_id: str, session_id=None):
    """Shared setup for the audio-only and slides-only pipelines: fetch the
    API JSON, build the timeline, and resolve the output directory.
    """
    json_data_url = construct_json_data_url(event_session_id=event_sessions, recording_id=record_id)
    json_data = fetch_json_data(url=json_data_url, session_id=session_id)

    if not json_data:
        logging.error('Failed to fetch webinar data. Check the session ID or URL.')
        return None

    total_duration = float(json_data.get('duration', 0))
    if not total_duration:
        raise ValueError('Duration not found in JSON data.')

    timeline = StreamTimeline()
    timeline.build(json_data)

    sanitized_name = re.sub(r'[\s\/:*?"<>|]+', '_', json_data['name'])
    directory = create_directory_if_not_exists(sanitized_name)

    return json_data, timeline, sanitized_name, directory, total_duration


def fetch_audio_only(event_sessions: str, record_id: str, session_id=None):
    """Download only the audio-bearing media and produce one mixed audio
    track, skipping video compositing entirely (no grid/presenter layout,
    no downloading of screenshare video, no slides) — built for a
    transcription pipeline (e.g. Whisper) that just needs the full audio
    mix, as fast and light as possible.
    """
    setup = _fetch_json_and_timeline(event_sessions, record_id, session_id)
    if not setup:
        return
    json_data, timeline, sanitized_name, directory, total_duration = setup

    # Screenshares are video-only (confirmed: no audio stream in the
    # container) and are usually the largest files by far — skip them.
    sessions = [s for s in timeline.sessions.values() if not s.is_screenshare]
    skipped = len(timeline.sessions) - len(sessions)
    logging.info(f'{len(sessions)} candidate audio sessions to download '
                 f'({skipped} screenshares skipped)')

    chunks = [(s.url, s.start_time) for s in sessions]
    downloaded = download_chunks_parallel(chunks, directory)

    prober = MediaProber()
    tracks = []
    for path, start_time, _conf_id, _is_admin in downloaded:
        info = prober.probe_file(path)
        if info['valid'] and info['has_audio']:
            tracks.append(AudioTrack(path=path, start_time=start_time))
    logging.info(f'{len(tracks)} of {len(downloaded)} downloaded sessions have audio')

    if not tracks:
        logging.error('No audio found in any downloaded session.')
        return

    tmp_dir = os.path.join(directory, '_tmp_audio')
    os.makedirs(tmp_dir, exist_ok=True)
    ffmpeg = FFmpegRunner()
    merger = AudioMerger(ffmpeg, prober)

    # AudioMerger.merge() overlays the mixed audio onto a video, so feed it
    # a throwaway silent placeholder and strip the video back out afterward
    # — reuses the existing, tested batched-amix pipeline as-is.
    placeholder = os.path.join(tmp_dir, 'placeholder.mp4')
    ffmpeg.run(
        [
            'ffmpeg', '-y', '-v', 'error',
            '-f', 'lavfi', '-i', f'color=c=black:s=16x16:d={total_duration}:r=1',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
            placeholder,
        ],
        description='generate placeholder video for audio mix',
    )

    mixed_video = os.path.join(tmp_dir, 'mixed_with_video.mp4')
    merger.merge(placeholder, tracks, tmp_dir, mixed_video, total_duration)

    audio_output = os.path.join(directory, f'{sanitized_name}.m4a')
    ffmpeg.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', mixed_video, '-vn', '-c:a', 'copy', audio_output],
        description='extract final audio track',
    )

    shutil.rmtree(tmp_dir, ignore_errors=True)
    logging.info(f'Audio saved to {audio_output}')

    return audio_output


def fetch_slides_only(event_sessions: str, record_id: str, session_id=None):
    """Download only the presentation slides, combine them into a single
    PDF (deduplicated, chronological order), and write a time-indexed
    manifest for aligning slides with a transcript. Does not touch any
    audio or video media.
    """
    setup = _fetch_json_and_timeline(event_sessions, record_id, session_id)
    if not setup:
        return
    json_data, timeline, sanitized_name, directory, total_duration = setup

    slide_events = timeline.get_slide_events_as_dicts()
    if not slide_events:
        logging.info('No presentation slides found for this recording.')
        return

    downloaded_slides = download_slide_images(slide_events, directory)

    slides_manifest = []
    for i, se in enumerate(downloaded_slides):
        end_time = (downloaded_slides[i + 1]['time']
                    if i + 1 < len(downloaded_slides) else total_duration)
        slides_manifest.append({
            'slide_number': se['slide_number'],
            'start_time': se['time'],
            'end_time': end_time,
            'image_path': se['local_path'],
        })

    pdf_path = None
    if downloaded_slides:
        pdf_path = combine_slides_to_pdf(
            downloaded_slides, os.path.join(directory, f'{sanitized_name}_slides.pdf')
        )

    manifest_path = os.path.join(directory, 'slides_manifest.json')
    with open(manifest_path, 'w', encoding='utf-8') as f:
        json.dump({
            'slides_pdf_path': pdf_path,
            'total_duration': total_duration,
            'slides': slides_manifest,
        }, f, indent=2, ensure_ascii=False)
    logging.info(f'Slide manifest saved to {manifest_path} ({len(slides_manifest)} slides)')

    return pdf_path, manifest_path

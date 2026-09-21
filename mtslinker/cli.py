import argparse
import logging
import re
from mtslinker.webinar import fetch_webinar_data, fetch_audio_only, fetch_slides_only

def parse_arguments():
    parser = argparse.ArgumentParser(
        description='mtslinker - tool for downloading MTS Link webinars.'
    )
    parser.add_argument(
        'url',
        help=(
            'Webinar link in one of the following formats: '
            'https://my.mts-link.ru/12345678/987654321/record-new/123456789/record-file/1234567890 or '
            'https://my.mts-link.ru/12345678/987654321/record-new/123456789'
        )
    )
    parser.add_argument(
        '--session-id',
        help='[Optional] sessionId token for accessing private recordings.'
    )
    parser.add_argument(
        '--audio-only',
        action='store_true',
        help=(
            '[Optional] Skip video compositing entirely. Downloads only '
            'audio-bearing media and mixes it into one audio track — for '
            'transcription pipelines (e.g. Whisper) that need just audio, '
            'not video. Combine with --slides-only to also get slides.'
        ),
    )
    parser.add_argument(
        '--slides-only',
        action='store_true',
        help=(
            '[Optional] Downloads presentation slide images, combines '
            'them into one PDF, and writes a time-indexed slide manifest. '
            'Does not touch any audio or video media. Combine with '
            '--audio-only to also get the audio mix.'
        ),
    )
    return parser.parse_args()

def extract_ids_from_url(url: str):
    url_pattern = (
        r'^https://my\.mts-link\.ru/(?:[^/]+/)?\d+/\d+/record-new/(\d+)(?:/record-file/(\d+))?$'
    )
    match = re.match(url_pattern, url)

    if match:
        # If there's a second capturing group, it's for the recording ID
        event_sessions = match.group(1)
        record_id = match.group(2) if match.group(2) else None
        return event_sessions, record_id
    
    return None, None

def main():
    logging.basicConfig(level=logging.INFO)

    args = parse_arguments()

    ids = extract_ids_from_url(args.url)
    if not ids:
        logging.error('Invalid URL format. Please check the link.')
        return

    event_sessions, record_id = ids

    logging.info(f'Starting download: event_sessions={event_sessions}, record_id={record_id}')

    if args.audio_only or args.slides_only:
        ok = True
        if args.audio_only:
            ok = bool(fetch_audio_only(
                event_sessions=event_sessions,
                record_id=record_id,
                session_id=args.session_id,
            )) and ok
        if args.slides_only:
            ok = bool(fetch_slides_only(
                event_sessions=event_sessions,
                record_id=record_id,
                session_id=args.session_id,
            )) and ok
        if ok:
            logging.info('Download completed.')
    elif fetch_webinar_data(
        event_sessions=event_sessions,
        record_id=record_id,
        session_id=args.session_id
    ):
        logging.info('Download completed.')

if __name__ == '__main__':
    main()

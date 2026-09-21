#!/usr/bin/env python3
"""Configure Android application identity and prepare App Link association."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', ANDROID)


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--application-id', required=True)
    parser.add_argument('--link-domain')
    parser.add_argument('--sha256', help='SHA-256 fingerprint of the APK signing certificate')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+', args.application_id):
        parser.error('application-id must be a dotted Java package identifier')
    if args.link_domain and not re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', args.link_domain):
        parser.error('link-domain must be a bare DNS name')
    if bool(args.link_domain) != bool(args.sha256):
        parser.error('link-domain and sha256 must be supplied together')
    digest = (args.sha256 or '').replace(':', '').upper()
    if args.sha256 and not re.fullmatch('[0-9A-F]{64}', digest):
        parser.error('sha256 must contain 32 hexadecimal bytes')
    gradle = ROOT / 'app/android/app/build.gradle.kts'
    text, count = re.subn(r'applicationId = "[^"]+"', f'applicationId = "{args.application_id}"', gradle.read_text())
    if count != 1:
        parser.error('Expected exactly one applicationId setting')
    gradle.write_text(text)
    path = ROOT / 'app/android/app/src/main/AndroidManifest.xml'
    tree = ET.parse(path)
    activity = tree.find('./application/activity')
    assert activity is not None
    for item in list(activity.findall('intent-filter')):
        if item.get(f'{{{ANDROID}}}autoVerify') == 'true':
            activity.remove(item)
    def Node(parent, tag, **attrs):
        return ET.SubElement(parent, tag, {f'{{{ANDROID}}}{key}': value for key, value in attrs.items()})
    if args.link_domain:
        entry = Node(activity, 'intent-filter', autoVerify='true')
        Node(entry, 'action', name='android.intent.action.VIEW')
        Node(entry, 'category', name='android.intent.category.DEFAULT')
        Node(entry, 'category', name='android.intent.category.BROWSABLE')
        Node(entry, 'data', scheme='https', host=args.link_domain.lower(), pathPrefix='/r/')
        dest = ROOT / 'dist/android-links/.well-known/assetlinks.json'
        dest.parent.mkdir(parents=True, exist_ok=True)
        fingerprint = ':'.join(digest[i:i + 2] for i in range(0, 64, 2))
        dest.write_text(json.dumps([{'relation': ['delegate_permission/common.handle_all_urls'], 'target': {
            'namespace': 'android_app', 'package_name': args.application_id, 'sha256_cert_fingerprints': [fingerprint],
        }}], indent=2) + '\n')
        print(f'Publish {dest} at https://{args.link_domain}/.well-known/assetlinks.json')
    ET.indent(tree, space='    ')
    tree.write(path, encoding='utf-8', xml_declaration=True)
    print('Android identity configured. Association files have not been published.')


if __name__ == '__main__':
    Main()

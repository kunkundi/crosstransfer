#!/usr/bin/env python3
"""Configure iOS identifiers and optionally prepare Universal Link association.

Run before pod install / signing. Does not register IDs or publish domain files.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--team-id')
    parser.add_argument('--link-domain')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id):
        parser.error('bundle-id must be a reverse DNS identifier')
    if args.team_id and not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
        parser.error('team-id must contain 10 uppercase letters/digits')
    if args.link_domain and (not args.team_id or not re.fullmatch(
            r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}', args.link_domain)):
        parser.error('link-domain requires team-id and a bare DNS domain (no scheme or path)')
    config = f'CT_BUNDLE_ID = {args.bundle_id}\nCT_APP_GROUP = group.$(CT_BUNDLE_ID)\n'
    if args.team_id:
        config += f'DEVELOPMENT_TEAM = {args.team_id}\n'
    (ROOT / 'app/ios/Flutter/Branding.xcconfig').write_text(config)
    entitlements = {'com.apple.security.application-groups': ['$(CT_APP_GROUP)']}
    for target in ('Runner', 'ShareExtension'):
        values = dict(entitlements)
        if target == 'Runner' and args.link_domain:
            values['com.apple.developer.associated-domains'] = [f'applinks:{args.link_domain.lower()}']
        (ROOT / f'app/ios/{target}/{target}.entitlements').write_bytes(plistlib.dumps(values))
    if args.link_domain:
        dest = ROOT / 'dist/ios-links/.well-known/apple-app-site-association'
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps({'applinks': {'apps': [], 'details': [{
            'appID': f'{args.team_id}.{args.bundle_id}', 'paths': ['/r/*'],
        }]}}, indent=2) + '\n')
        print(f'Publish {dest} at https://{args.link_domain}/.well-known/apple-app-site-association')
        print('Use application/json over HTTPS, without redirects. Set the same link host in the app.')
    print('Configured Runner and ShareExtension. Register both IDs and the App Group before signing.')


if __name__ == '__main__':
    Main()

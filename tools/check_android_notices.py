#!/usr/bin/env python3
"""Verify Android runtime copyright/license evidence from resolved Maven files.

Run :app:verifyRuntimeLicenses and a release build first. --write updates reviewed
notice assets, not the allowed dependency graph. Flutter's own Maven artifacts
use the engine/SDK notices already collected into Flutter NOTICES.Z.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NS = {"m": "http://maven.apache.org/POM/4.0.0"}


def Hash(data):
    return hashlib.sha256(data).hexdigest()


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle-cache", type=Path, default=Path.home() / ".gradle/caches/modules-2/files-2.1")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    components, sections = [], []

    def ReadPom(group, artifact, version):
        files = list((args.gradle_cache / group / artifact / version).rglob("*.pom"))
        assert len(files) <= 1, f"ambiguous POM: {group}:{artifact}:{version}"
        if files:
            data = files[0].read_bytes()
        else:
            # Gradle module metadata can avoid fetching parent POMs. Retrieve
            # only public metadata; the reviewed manifest pins its exact hash.
            suffix = group.replace(".", "/") + f"/{artifact}/{version}/{artifact}-{version}.pom"
            repositories = (["https://storage.googleapis.com/download.flutter.io/"] if group == "io.flutter" else
                            ["https://dl.google.com/dl/android/maven2/", "https://repo.maven.apache.org/maven2/"])
            data = None
            for repository in repositories:
                try:
                    data = urllib.request.urlopen(repository + suffix, timeout=30).read()
                    break
                except urllib.error.HTTPError as error:
                    if error.code != 404:
                        raise
            assert data is not None, f"missing POM: {group}:{artifact}:{version}"
        return ET.fromstring(data), dict(coordinate=f"{group}:{artifact}:{version}", sha256=Hash(data))

    for coordinate in (ROOT / "docs/licenses/android-runtime-modules.txt").read_text().splitlines():
        group, artifact, version = coordinate.split(":")
        pom, evidence = ReadPom(group, artifact, version)
        component = dict(coordinate=coordinate, poms=[evidence], artifacts=[], notices=[])
        if group == "io.flutter":
            component["license_delivery"] = "Flutter SDK/engine NOTICES.Z"
            components.append(component)
            continue
        current = pom
        licenses = current.findall("m:licenses/m:license", NS)
        for _ in range(5):
            if licenses:
                break
            parent = current.find("m:parent", NS)
            assert parent is not None, f"license missing: {coordinate}"
            current, evidence = ReadPom(*(parent.findtext("m:" + key, namespaces=NS)
                                          for key in ("groupId", "artifactId", "version")))
            component["poms"].append(evidence)
            licenses = current.findall("m:licenses/m:license", NS)
        component["licenses"] = [dict(name=value.findtext("m:name", namespaces=NS),
                                      url=value.findtext("m:url", namespaces=NS)) for value in licenses]
        assert licenses and all("Apache" in value["name"] for value in component["licenses"]), \
            f"unreviewed license: {coordinate}: {component['licenses']}"
        component["license"] = "Apache-2.0"
        component["source"] = (pom.findtext("m:scm/m:url", namespaces=NS) or
                               pom.findtext("m:url", namespaces=NS) or
                               current.findtext("m:scm/m:url", namespaces=NS) or
                               current.findtext("m:url", namespaces=NS) or
                               "https://repo.maven.apache.org/maven2/" + group.replace(".", "/") + f"/{artifact}/{version}/")
        authors = [element.text for element in pom.findall("m:developers/m:developer/m:name", NS)]
        sections.append(coordinate + "\nSource: " + component["source"] +
                        ("\nUpstream developer attribution: " + ", ".join(authors) if authors else "") +
                        "\nLicense: Apache-2.0 (full text above)\n")

        def Collect(archive, prefix):
            for name in sorted(archive.namelist()):
                if name.endswith("/"):
                    continue
                if any(token in name.rsplit("/", 1)[-1].upper() for token in ("LICENSE", "NOTICE", "COPYING")):
                    data = archive.read(name)
                    component["notices"].append(dict(path=prefix + name, sha256=Hash(data)))
                    sections.append(prefix + name + "\n\n" + data.decode("utf-8").strip() + "\n")
                elif name == "classes.jar":
                    with zipfile.ZipFile(io.BytesIO(archive.read(name))) as nested:
                        Collect(nested, prefix + "classes.jar/")

        directory = args.gradle_cache / group / artifact / version
        for file in sorted(directory.rglob("*")):
            if file.suffix not in (".aar", ".jar") or file.name.endswith(("-sources.jar", "-javadoc.jar")):
                continue
            component["artifacts"].append(dict(file=file.name, sha256=Hash(file.read_bytes())))
            with zipfile.ZipFile(file) as archive:
                Collect(archive, file.name + ":")
        components.append(component)
    apache = (ROOT / "docs/licenses/apache-2.0.txt").read_text()
    text = ("Android runtime dependencies\n\n" + apache + "\n\n" +
            ("\n" + "=" * 72 + "\n\n").join(sections)).encode()
    manifest = dict(schema_version=1, components=components, notices_sha256=Hash(text))
    outputs = [(ROOT / "docs/licenses/android_manifest.json", (json.dumps(manifest, indent=2) + "\n").encode()),
               (ROOT / "docs/licenses/android-runtime.txt", text),
               (ROOT / "app/assets/legal/android-runtime.txt", text)]
    for path, data in outputs:
        if args.write:
            path.write_bytes(data)
        else:
            assert path.read_bytes() == data, f"stale Android license evidence: {path}"
    print(f"PASS: {len(components)} Android Maven coordinates, POM provenance and bundled notices")


if __name__ == "__main__":
    Main()

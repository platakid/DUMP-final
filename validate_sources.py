#!/usr/bin/env python3
"""Portable structural checks only. This is NOT a Swift compiler or an XCTest run."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def openstep(text):
    tokens = re.findall(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text, re.S)
    tokens = [t for t in tokens if not t.startswith(('//', '/*'))]
    index = 0

    def pop(expected=None):
        nonlocal index
        token = tokens[index]
        index += 1
        if expected is not None:
            assert token == expected, (expected, token)
        return token

    def value():
        token = pop()
        if token == '{':
            result = {}
            while tokens[index] != '}':
                key = pop().strip('"')
                pop('=')
                assert key not in result, ('Duplicate object/key', key)
                result[key] = value()
                pop(';')
            pop('}')
            return result
        if token == '(':
            result = []
            while tokens[index] != ')':
                result.append(value())
                if tokens[index] != ')':
                    pop(',')
            pop(')')
            return result
        return token.strip('"')

    result = value()
    assert index == len(tokens)
    return result


def main():
    objects = openstep((ROOT / 'DUMP.xcodeproj/project.pbxproj').read_text())['objects']
    compiled = set()
    for target in [o for o in objects.values() if o.get('isa') == 'PBXNativeTarget']:
        paths = []
        for phase_id in target['buildPhases']:
            phase = objects[phase_id]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                for build_id in phase['files']:
                    path = objects[objects[build_id]['fileRef']]['path']
                    assert (ROOT / path).is_file(), path
                    paths.append(path)
        assert len(paths) == len(set(paths)), 'Duplicate Compile Sources entry'
        if target['name'] == 'DUMP':
            assert all(p.startswith('DUMP/DUMP/') for p in paths)
        if target['name'] == 'DUMPTests':
            assert all(p.startswith('DUMPTests/') for p in paths)
        compiled.update(paths)
        print(f"PASS: {target['name']}: {len(paths)} explicit Compile Sources entries")
    actual = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*.swift')}
    assert actual == compiled, ('Unregistered/missing source', actual ^ compiled)

    info = plistlib.loads((ROOT / 'DUMP/DUMP/Info.plist').read_bytes())
    for key in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
                'NSFaceIDUsageDescription', 'NSPhotoLibraryUsageDescription',
                'NSPhotoLibraryAddUsageDescription']:
        assert info[key]
    assert info['UIFileSharingEnabled'] is False
    ET.parse(ROOT / 'DUMP.xcodeproj/xcshareddata/xcschemes/DUMP.xcscheme')
    print('PASS: Info.plist privacy keys and shared scheme XML')

    capture = '\n'.join(p.read_text() for p in (ROOT / 'DUMP/DUMP/Media').glob('Secure*.swift'))
    for forbidden in ['AVCaptureMovieFileOutput', 'AVAssetWriter', 'PHPhotoLibrary',
                      'NSTemporaryDirectory', 'livePhotoMovieFileURL', 'UIImageWriteToSavedPhotosAlbum']:
        assert forbidden not in capture, forbidden
    print('PASS: new capture/player source has no movie-file recording or Photos write API')
    tests = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in (ROOT / 'DUMPTests').glob('*.swift'))
    print(f'INFO: {tests} XCTest cases supplied; not executed by this check')
    print('NOT CHECKED: Swift syntax/type checking, linking, XCTest execution, camera or decoder behavior')


if __name__ == '__main__':
    main()

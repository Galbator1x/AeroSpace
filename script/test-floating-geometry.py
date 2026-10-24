#!/usr/bin/env python3
"""Run floating-geometry XCTest methods against a SwiftPM debug build without XCTest.

This CLT fallback uses real AppBundle objects and test fixtures, but does not
replace Apple's XCTest runner or interactive Accessibility validation.
"""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True, help='SwiftPM platform debug directory')
parser.add_argument('--sdk', type=Path, required=True)
parser.add_argument('--filter', default='', help='Substring of the test method name')
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parent.parent)
args = parser.parse_args()
root = args.repo.resolve()
build = args.build_dir.resolve()
util = (root / 'Sources/AppBundleTests/testUtil.swift').read_text()
setup = util[util.index('@MainActor\nfunc setUpWorkspacesForTests()'):util.index('\nextension ParsedCmd')]
harness = '''@testable import AppBundle
import Common
import AppKit
import Foundation
@objc(XCTestCase) class XCTestCase: NSObject {
    @MainActor func setUp() async throws {}
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \\(b), got \\(a)") }
func XCTAssertTrue(_ v: Bool) { precondition(v) }
func XCTAssertFalse(_ v: Bool) { precondition(!v) }
func XCTAssertNil<T>(_ v: T?) { precondition(v == nil, "Expected nil, got \\(String(describing: v))") }
func XCTAssertNotNil<T>(_ v: T?) { precondition(v != nil) }
func XCTFail(_ message: String) { preconditionFailure(message) }
''' + setup
calls = []
for filename in ['ClosedWindowGeometryTest', 'PersistentFloatingGeometryTest', 'ReopenedGeometryLifecycleTest']:
    source = (root / 'Sources/AppBundleTests/tree' / (filename + '.swift')).read_text()
    harness += '\n' + source.replace('import XCTest', '')
    for method, modifiers in re.findall(r'    func (test\w+)\(\)([^\{]*)\{', source):
        if args.filter not in method:
            continue
        prefix = ('try ' if 'throws' in modifiers else '') + ('await ' if 'async' in modifiers else '')
        calls.append(f'''        do {{
            let test = {filename}()
            try await test.setUp()
            print("RUN {filename}.{method}")
            {prefix}test.{method}()
            print("PASS {filename}.{method}")
        }}''')
if not calls:
    parser.error('No matching tests')
harness += '\n@main struct Regression {\n    @MainActor static func main() async throws {\n        precondition(isUnitTest)\n' + '\n'.join(calls) + '\n    }\n}\n'
objects = shlex.split((build / 'AeroSpaceApp.product/Objects.LinkFileList').read_text())
objects = [o for o in objects if '/AeroSpaceApp.build/' not in o]
with tempfile.TemporaryDirectory(prefix='aerospace-geometry-tests-') as temporary:
    temp = Path(temporary)
    source = temp / 'Regression.swift'
    source.write_text(harness)
    executable = temp / 'regression'
    command = ['swiftc', '-swift-version', '6', '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault',
               '-strict-memory-safety', '-sdk', str(args.sdk), '-module-cache-path', str(temp / 'modules'),
               '-I', str(build / 'Modules'), '-Xcc', '-fmodule-map-file=' + str(root / 'Sources/PrivateApi/include/module.modulemap'),
               str(source), str(root / 'Sources/AppBundleTests/tree/TestApp.swift'),
               str(root / 'Sources/AppBundleTests/tree/TestWindow.swift'), *objects, '-o', str(executable)]
    compiled = subprocess.run(command)
    if compiled.returncode:
        raise SystemExit(compiled.returncode)
    result = subprocess.run([str(executable)])
    raise SystemExit(result.returncode)

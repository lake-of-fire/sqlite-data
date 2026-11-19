#!/usr/bin/env python3
"""Check the opt-in manifest and source exclusion without claiming Apple compilation."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def verify_manifest(package):
    traits = {trait["name"]: trait for trait in package["traits"]}
    assert "AppExtensionSafe" in traits, "Missing AppExtensionSafe trait"
    assert traits["AppExtensionSafe"]["enabledTraits"] == [], "The trait must remain narrowly scoped"
    assert all(
        "AppExtensionSafe" not in trait["enabledTraits"]
        for name, trait in traits.items()
        if name != "AppExtensionSafe"
    ), "Other/default traits must not implicitly opt into extension behavior"

    definitions = []
    for target in package["targets"]:
        for setting in target.get("settings", []):
            kind = setting["kind"]
            assert "unsafeFlags" not in kind, "Do not bypass extension checking with unsafe flags"
            if kind.get("define", {}).get("_0") == "SQLITE_DATA_APP_EXTENSION":
                definitions.append((target["name"], setting))
    assert len(definitions) == 1, "Exactly one target must receive the extension define"
    target, setting = definitions[0]
    assert target == "SQLiteData", "The define belongs only to SQLiteData"
    assert setting["tool"] == "swift"
    assert setting["condition"].get("traits") == ["AppExtensionSafe"], "The define must be opt-in"
    assert not setting["condition"].get("config"), "Debug and release must agree"


def verify_source(root):
    guard = "os(iOS) && !SQLITE_DATA_APP_EXTENSION"
    references = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        stack = []
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            text = line.strip()
            if text.startswith("#if "):
                stack.append(text[4:])
            elif text.startswith("#elseif "):
                assert stack, f"Unexpected conditional: {path}:{number}"
                stack[-1] = text[8:]
            elif text == "#else":
                assert stack, f"Unexpected else: {path}:{number}"
                stack[-1] = "else"
            elif text == "#endif":
                assert stack, f"Unexpected endif: {path}:{number}"
                stack.pop()
            elif not text.startswith("//") and re.search(r"\bUIApplication\s*\.\s*shared\b", text):
                assert guard in stack, f"App-only singleton escapes its guard: {path}:{number}"
                references.append((str(path.relative_to(root)), number, text))
        assert not stack, f"Unclosed conditional: {path}"

    assert len(references) == 2, "Review changes to the set of app-only singleton calls"
    assert all(path == "Sources/SQLiteData/CloudKit/SyncEngine.swift" for path, _, _ in references)
    assert any("beginBackgroundTask()" in line for _, _, line in references)
    assert any("endBackgroundTask(taskIdentifier)" in line for _, _, line in references)
    source = (root / "Sources/SQLiteData/CloudKit/SyncEngine.swift").read_text()
    assert "forName: UIApplication.willResignActiveNotification" in source
    return [{"path": path, "line": number} for path, number, _ in references]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    command = subprocess.run(
        [args.swift, "package", "dump-package"], cwd=root,
        check=True, text=True, capture_output=True, timeout=60,
    )
    package = json.loads(command.stdout)
    verify_manifest(package)
    references = verify_source(root)
    print(json.dumps({
        "result": "passed",
        "trait": "AppExtensionSafe",
        "target": "SQLiteData",
        "define": "SQLITE_DATA_APP_EXTENSION",
        "manifestParsedBySwiftPM": True,
        "guardedAppSingletonReferences": references,
        "appleSDKTypechecked": False,
        "appExtensionBinaryBuilt": False,
    }, indent=2))


if __name__ == "__main__":
    main()

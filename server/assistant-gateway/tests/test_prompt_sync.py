"""The system prompt is duplicated, so something has to compare the two copies.

It lives here as ``SYSTEM_PROMPT`` and in the App as ``assistantSystemPrompt``.
The App's direct-to-model mode never touches this server, so the App's copy has
to carry the same safety rules on its own — but nothing at run time compares
them, and a drift would only show up as one of the two online paths quietly
having weaker constraints. This test is that comparison.
"""

import pathlib
import re
import unittest

from gateway import SYSTEM_PROMPT

DART_PROMPT = (
    pathlib.Path(__file__).resolve().parents[3]
    / "mobile_app"
    / "lib"
    / "assistant"
    / "assistant_prompt.dart"
)


def read_dart_prompt(path):
    """Return the assistantSystemPrompt value with its adjacent parts joined.

    Dart splits the text across several adjacent string literals; the
    concatenation is exactly the prompt the App sends.
    """
    source = path.read_text(encoding="utf-8")
    try:
        body = source.split("const String assistantSystemPrompt =", 1)[1].split(";", 1)[0]
    except IndexError:
        raise AssertionError(f"assistantSystemPrompt not found in {path}") from None
    if "\\" in body:
        raise AssertionError(
            f"assistantSystemPrompt in {path} uses a backslash escape; "
            "teach read_dart_prompt about it instead of comparing unequal text"
        )
    parts = re.findall(r"'([^']*)'", body)
    if not parts:
        raise AssertionError(f"no string literal found for assistantSystemPrompt in {path}")
    return "".join(parts)


class PromptSyncTests(unittest.TestCase):
    def test_the_app_prompt_file_is_where_this_test_expects_it(self):
        # A moved or renamed file must fail loudly, not silently skip the check.
        self.assertTrue(DART_PROMPT.is_file(), f"missing {DART_PROMPT}")

    def test_the_app_and_the_server_share_one_system_prompt(self):
        self.assertEqual(read_dart_prompt(DART_PROMPT), SYSTEM_PROMPT)

    def test_the_prompt_still_forbids_diagnosis_and_dosing(self):
        # Guards the edit that would make the two copies agree on something wrong.
        for phrase in ("Do not diagnose", "recommend doses", "do not verify ingestion"):
            self.assertIn(phrase, SYSTEM_PROMPT)


if __name__ == "__main__":
    unittest.main()

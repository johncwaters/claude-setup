import unittest

from src.validators import render_message, validate_message

VALID = {
    "type": "fix",
    "scope": "auth",
    "description": "reject expired tokens on refresh",
    "body": "Refresh was accepting expired tokens because the exp check compared\nthe wrong field.",
    "trailers": {
        "constraint": None,
        "rejected": None,
        "directive": None,
        "confidence": "high",
        "scope_risk": "narrow",
        "not_tested": None,
    },
    "trivial": False,
}


class ValidateMessageTests(unittest.TestCase):
    def test_valid_message_passes(self):
        self.assertEqual(validate_message(VALID), [])

    def test_em_dash_rejected(self):
        bad = dict(VALID, body=VALID["body"] + " note — this matters")
        errors = validate_message(bad)
        self.assertTrue(any("banned characters" in e for e in errors))

    def test_en_dash_rejected(self):
        bad = dict(VALID, body=VALID["body"] + " pages 1–10")
        errors = validate_message(bad)
        self.assertTrue(any("banned characters" in e for e in errors))

    def test_emoji_rejected(self):
        bad = dict(VALID, description=VALID["description"] + " \U0001F600")
        errors = validate_message(bad)
        self.assertTrue(any("banned characters" in e for e in errors))

    def test_bad_type_rejected(self):
        bad = dict(VALID, type="feature")
        errors = validate_message(bad)
        self.assertTrue(any("type must be one of" in e for e in errors))

    def test_long_description_rejected(self):
        bad = dict(VALID, description="x" * 73)
        errors = validate_message(bad)
        self.assertTrue(any("72 characters" in e for e in errors))

    def test_trailing_period_rejected(self):
        bad = dict(VALID, description=VALID["description"] + ".")
        errors = validate_message(bad)
        self.assertTrue(any("trailing period" in e for e in errors))

    def test_valid_message_renders_exactly(self):
        rendered = render_message(VALID)
        expected = (
            "fix(auth): reject expired tokens on refresh\n"
            "\n"
            "Refresh was accepting expired tokens because the exp check compared\n"
            "the wrong field.\n"
            "\n"
            "Confidence: high\n"
            "Scope-risk: narrow"
        )
        self.assertEqual(rendered, expected)

    def test_trivial_skips_trailers(self):
        trivial = dict(
            VALID,
            trivial=True,
            trailers={
                "constraint": None,
                "rejected": None,
                "directive": None,
                "confidence": None,
                "scope_risk": None,
                "not_tested": None,
            },
        )
        self.assertEqual(validate_message(trivial), [])
        rendered = render_message(trivial)
        self.assertNotIn("Confidence:", rendered)
        self.assertNotIn("Scope-risk:", rendered)

    def test_missing_trailers_rejected_when_not_trivial(self):
        bad = dict(
            VALID,
            trailers={
                "constraint": None,
                "rejected": None,
                "directive": None,
                "confidence": None,
                "scope_risk": None,
                "not_tested": None,
            },
        )
        errors = validate_message(bad)
        self.assertTrue(any("confidence trailer" in e for e in errors))
        self.assertTrue(any("scope_risk trailer" in e for e in errors))

    def test_no_scope_renders_without_parens(self):
        no_scope = dict(VALID, scope=None, trivial=True)
        rendered = render_message(no_scope)
        self.assertTrue(rendered.startswith("fix: reject expired tokens on refresh"))


if __name__ == "__main__":
    unittest.main()

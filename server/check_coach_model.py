"""Opt-in release check with public, invented examples and no learner state."""
import argparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="call the configured Tencent Token Plan")
    if not parser.parse_args().live:
        parser.exit(message="Use --live in a configured test environment to call the provider.\n")

    from app.coach_studio import prepare_material, reply_feedback
    from app.main import hunyuan_chat

    def edit(prompt):
        return hunyuan_chat(prompt, temperature=0.15, max_tokens=360)

    def write(prompt):
        return hunyuan_chat(prompt, temperature=0.55, max_tokens=3800)

    material = prepare_material(write, edit, "condition", "work", 2500, ["confirm"], "区分条件和事实")
    print(f"Reviewed {len(material['cards'])} new scenes.")

    passage = "The main gate is closed. Please meet me at the west entrance at eight instead."
    reference = "See you at the west entrance at eight."
    cases = (
        ("paraphrase", "I'll be at the west gate at eight.", {"表达清楚"}),
        ("clarification", "Do you mean the west entrance, at eight?", {"表达清楚"}),
        ("contradiction", "See you at the main gate at eight.", {"可以更明确"}),
        ("irrelevant", "The sea is made of paper clips.", {"暂无法判断", "可以更明确"}),
    )
    misses = 0
    for label, answer, expected in cases:
        result = reply_feedback(edit, passage, "八点在西门集合", answer, reference)
        verdict = result["verdict"]
        print(f"{label}: {verdict}")
        misses += verdict not in expected
    print(f"Matched {len(cases)-misses}/{len(cases)} reference cases.")
    return int(misses != 0)


if __name__ == "__main__":
    raise SystemExit(main())

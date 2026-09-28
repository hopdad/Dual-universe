"""The skills registry (packages/protocol/skills.json) as the hub and the planner get it."""

import json

from conftest import ROOT
from jsonschema import Draft202012Validator

from dufleet.protocol import generated as g

SOURCE = json.loads((ROOT / "packages" / "protocol" / "skills.json").read_text(encoding="utf-8"))


def test_every_registered_skill_can_be_run():
    assert g.SKILL_REGISTRY
    for name in g.SKILL_REGISTRY:
        assert name in g.SKILLS, name


def test_the_args_schema_takes_the_examples_the_bus_takes():
    # lua/spec/skills_spec.lua runs the same examples through the bus's own check
    for name, skill in g.SKILL_REGISTRY.items():
        Draft202012Validator.check_schema(skill["args_schema"])
        validator = Draft202012Validator(skill["args_schema"])
        examples = SOURCE[name]["examples"]
        for args in examples["valid"]:
            assert validator.is_valid(args), (name, args)
        for args in examples["invalid"]:
            assert not validator.is_valid(args), (name, args)

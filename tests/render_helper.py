"""Shared test helper: renders a "@@VAR@@" template and imports it as a
real module, so tests can exercise the actual logic in the .template.py
files (no macOS host, Keychain, or network needed) instead of duplicating
it.
"""
import importlib.util
import re


def render_and_import(template_path, module_name, **substitutions):
  with open(template_path) as f:
    content = f.read()
  for name, value in substitutions.items():
    content = content.replace(f"@@{name}@@", str(value))
  remaining = re.findall(r"@@\w+@@", content)
  if remaining:
    raise ValueError(f"Unsubstituted placeholders in {template_path}: {remaining}")
  spec = importlib.util.spec_from_loader(module_name, loader=None)
  module = importlib.util.module_from_spec(spec)
  exec(compile(content, template_path, "exec"), module.__dict__)
  return module

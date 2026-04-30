#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
RBAC_ROOT = REPO_ROOT / "infrastructure" / "rbac"
RBAC_MODEL = REPO_ROOT / "docs" / "architecture" / "rbac-model.md"


def split_yaml_documents(text: str) -> List[str]:
    parts = re.split(r"(?m)^---\s*$", text)
    return [part.strip() for part in parts if part.strip()]


def extract_block(text: str, block_name: str) -> Optional[str]:
    match = re.search(rf"(?ms)^({block_name}:\s*\n(?:^[ ]+.*\n?)*)", text)
    if not match:
        return None
    return match.group(1)


def extract_top_level_scalar(text: str, key: str) -> Optional[str]:
    match = re.search(rf"(?m)^{re.escape(key)}:\s*([^\n#]+)", text)
    if not match:
        return None
    return match.group(1).strip().strip('"\'')


def extract_nested_scalar(block: Optional[str], key: str) -> Optional[str]:
    if not block:
        return None
    match = re.search(rf"(?m)^[ ]+{re.escape(key)}:\s*([^\n#]+)", block)
    if not match:
        return None
    return match.group(1).strip().strip('"\'')


class Resource:
    def __init__(self, kind: str, name: str, namespace: Optional[str], path: Path, text: str):
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.path = path
        self.text = text


def load_rbac_resources() -> List[Resource]:
    resources: List[Resource] = []
    for path in sorted(RBAC_ROOT.rglob("*.yaml")):
        text = path.read_text(encoding="utf-8")
        for document in split_yaml_documents(text):
            kind = extract_top_level_scalar(document, "kind")
            metadata = extract_block(document, "metadata")
            name = extract_nested_scalar(metadata, "name")
            namespace = extract_nested_scalar(metadata, "namespace")
            if kind and name:
                resources.append(Resource(kind=kind, name=name, namespace=namespace, path=path, text=document))
    return resources


def load_documented_clusterroles() -> Dict[str, str]:
    text = RBAC_MODEL.read_text(encoding="utf-8")
    section_match = re.search(
        r"(?ms)^### 1\.1 ClusterRole Definitions\n(.*?)^### 1\.2 Binding Model",
        text,
    )
    if not section_match:
        raise RuntimeError("Could not find ClusterRole Definitions section in RBAC model")

    section = section_match.group(1)
    documented: Dict[str, str] = {}
    for match in re.finditer(r"(?ms)^#### `([^`]+)`\n.*?```yaml\n(.*?)\n```", section):
        documented[match.group(1)] = match.group(2).strip()
    if not documented:
        raise RuntimeError("Could not extract documented ClusterRoles from RBAC model")
    return documented


def check_binding_references(resources: Iterable[Resource]) -> Tuple[List[str], List[str]]:
    clusterroles = {resource.name for resource in resources if resource.kind == "ClusterRole"}
    roles = {
        (resource.namespace, resource.name)
        for resource in resources
        if resource.kind == "Role"
    }

    errors: List[str] = []
    notes: List[str] = []
    for resource in resources:
        if resource.kind not in {"RoleBinding", "ClusterRoleBinding"}:
            continue

        role_ref = extract_block(resource.text, "roleRef")
        ref_kind = extract_nested_scalar(role_ref, "kind")
        ref_name = extract_nested_scalar(role_ref, "name")
        if not ref_kind or not ref_name:
            errors.append(f"{resource.path}: {resource.kind}/{resource.name} is missing roleRef.kind or roleRef.name")
            continue

        if ref_kind == "ClusterRole":
            if ref_name not in clusterroles:
                errors.append(
                    f"{resource.path}: {resource.kind}/{resource.name} references missing ClusterRole '{ref_name}'"
                )
        elif ref_kind == "Role":
            key = (resource.namespace, ref_name)
            if key not in roles:
                errors.append(
                    f"{resource.path}: {resource.kind}/{resource.name} references missing Role '{ref_name}' in namespace '{resource.namespace or '<none>'}'"
                )
        else:
            notes.append(f"{resource.path}: {resource.kind}/{resource.name} uses unexpected roleRef.kind '{ref_kind}'")

    return errors, notes


def normalize_yaml_text(text: str) -> str:
    normalized_lines: List[str] = []
    for line in text.strip().splitlines():
        stripped = line.split("#", 1)[0].strip()
        if stripped:
            normalized_lines.append(stripped)
    return " ".join(normalized_lines)


def check_doc_conformance(resources: Iterable[Resource]) -> Tuple[List[str], List[str]]:
    documented = load_documented_clusterroles()
    manifest_clusterroles = {
        resource.name: resource
        for resource in resources
        if resource.kind == "ClusterRole"
    }

    errors: List[str] = []
    notes: List[str] = []

    for role_name, resource in manifest_clusterroles.items():
        if role_name not in documented:
            errors.append(f"{resource.path}: ClusterRole '{role_name}' is not documented in {RBAC_MODEL}")
            continue

        documented_text = normalize_yaml_text(documented[role_name])
        manifest_text = normalize_yaml_text(resource.text)
        if documented_text != manifest_text:
            errors.append(
                f"{resource.path}: ClusterRole '{role_name}' does not match the canonical definition in {RBAC_MODEL}"
            )

    undocumented = sorted(set(documented) - set(manifest_clusterroles))
    if undocumented:
        notes.append(
            "Documented ClusterRoles not yet implemented in manifests: " + ", ".join(undocumented)
        )

    return errors, notes


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Kubernetes RBAC manifests against repo rules")
    parser.add_argument(
        "check",
        nargs="?",
        default="all",
        choices=["all", "bindings", "conformance"],
        help="Which validation set to run",
    )
    args = parser.parse_args()

    resources = load_rbac_resources()
    all_errors: List[str] = []
    all_notes: List[str] = []

    if args.check in {"all", "bindings"}:
        errors, notes = check_binding_references(resources)
        all_errors.extend(errors)
        all_notes.extend(notes)

    if args.check in {"all", "conformance"}:
        errors, notes = check_doc_conformance(resources)
        all_errors.extend(errors)
        all_notes.extend(notes)

    for note in all_notes:
        print(f"NOTE: {note}")

    if all_errors:
        for error in all_errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"RBAC validation passed for {args.check}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

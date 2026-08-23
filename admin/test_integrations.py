"""Offline checks for admin/integrations.py: file stores round-trip, helpers,
and the registry can't drift from what the workflows / edge functions read.
Run: py -3 -m pytest admin/test_integrations.py"""
import pathlib
import re
import sys
import tomllib

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import integrations as I  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parent.parent


def test_envfile_roundtrip(tmp_path):
    p = tmp_path / ".env"
    p.write_text("# comment\nA=1\nB=2\nA=dup\n\nC=3\n", encoding="utf8")
    f = I.EnvFile(p)
    assert f.read() == {"A": "1", "B": "2", "C": "3"}   # first wins, like run.load_env
    assert f.duplicates() == ["A"]
    f.put("A", "new")
    f.put("D", "x,y")
    txt = p.read_text(encoding="utf8")
    assert txt.splitlines()[0] == "# comment"           # comments + order kept
    assert txt.count("A=") == 1 and "A=new" in txt       # duplicate dropped
    assert txt.rstrip().endswith("D=x,y")
    f.delete("B")
    assert "B=" not in p.read_text(encoding="utf8")


def test_tomlfile_roundtrip(tmp_path):
    p = tmp_path / "secrets.toml"
    p.write_text('ADMIN_PASSWORD = "pw"\n# note\nX = "1"\n', encoding="utf8")
    t = I.TomlFile(p)
    t.put("X", "2")
    t.put("J", '{"a":"b","n":1}')
    data = tomllib.loads(p.read_text(encoding="utf8"))   # still valid TOML
    assert data == {"ADMIN_PASSWORD": "pw", "X": "2", "J": '{"a":"b","n":1}'}
    assert t.names() == ["ADMIN_PASSWORD", "X", "J"]
    t.delete("X")
    assert "X" not in tomllib.loads(p.read_text(encoding="utf8"))


def test_helpers():
    assert I.fingerprint("AIzaSyABCDEFGHIJKLMNOP") == "AIzaSyAB…MNOP"
    assert I.fingerprint("short") == "•••••"
    assert I.split_list(" a, b ,,c ") == ["a", "b", "c"]
    assert I.join_list(["a", " b", ""]) == "a,b"
    assert I.edge_name(I.by_name("GEMINI_API_KEY")) == "GEMINI_API_KEYS"
    assert I.edge_name(I.by_name("TAVILY_API_KEY")) == "TAVILY_API_KEY"
    assert I.edge_name(I.by_name("FRED_API_KEY")) is None
    assert I.by_name("NEW_X", [{"name": "NEW_X", "group": "Custom"}])["shape"] == "single"
    assert I.yaml_snippet("NEW_X").strip() == "NEW_X: ${{ secrets.NEW_X }}"


def test_lint(tmp_path):
    p = tmp_path / ".env"
    p.write_text("GEMINI_API_KEY=a\nGEMINI_MODEL=x\nFOO=1\nFOO=2\n", encoding="utf8")
    kinds = {(k, n) for k, n, _ in I.lint_env(I.EnvFile(p))}
    assert ("dead", "GEMINI_MODEL") in kinds and ("duplicate", "FOO") in kinds and ("unknown", "FOO") in kinds


def test_registry_covers_workflows_and_edge():
    """Every secret the workflows pass, and every key env the edge functions
    read, must be a registry entry (or a documented non-secret)."""
    names = {s["name"] for s in I.SECRETS}
    wf = "".join((REPO / ".github/workflows" / f).read_text(encoding="utf8") for f in ("pipeline.yml", "watchdog.yml"))
    used = set(re.findall(r"secrets\.([A-Z0-9_]+)", wf))
    assert used - names == set(), used - names
    edge_names = {I.edge_name(s) for s in I.SECRETS if I.edge_name(s)}
    ts = "".join((REPO / "supabase/functions" / f / "index.ts").read_text(encoding="utf8") for f in ("qa", "deepread"))
    for env in re.findall(r'Deno\.env\.get\("([A-Z0-9_]+)"\)', ts):
        assert env in edge_names | {"SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SERVICE_KEY"}, env
    for env in ("GEMINI_API_KEYS", "GROQ_API_KEYS"):  # keysOf(...) literals
        assert env in ts and env in edge_names

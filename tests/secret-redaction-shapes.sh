#!/usr/bin/env bash
# Exact token-shape and zero-false-positive tests for secret_redact.RULES.
# Fake values are assembled at runtime so the path/token gate does not flag this file.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REDACTOR="${REDACTOR:-$REPO/tools/templates/hooks/secret_redact.py}"
ONLY="${ONLY:-}"

REDACTOR="$REDACTOR" ONLY="$ONLY" python3 - <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("secret_redact_under_test", os.environ["REDACTOR"])
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)
only = os.environ.get("ONLY", "")
ran = 0
ok = 0

def check(name, passed):
    global ran, ok
    if only and only != name:
        return
    ran += 1
    if passed:
        ok += 1
        print("ok   " + name)
    else:
        print("FAIL " + name)

def secret_shape(name, value, kind):
    text = "prefix " + value + " suffix"
    masked, kinds = sr.redact(text)
    check(name + "-masked", value not in masked and "<hidden>" in masked and kind in kinds)

def long_shape(name, value, kind):
    text = "prefix " + value + " suffix"
    masked, kinds = sr.redact(text)
    check(name + "-long-masked", value not in masked and "<hidden>" in masked and kind in kinds)
    check(name + "-no-tail", value[-8:] not in masked)

def short_shape(name, value):
    text = "prefix " + value + " suffix"
    check(name + "-short-kept", sr.redact(text) == (text, []))

# Generic assignment and the AWS variable-name suffix case.
aws = "A1" * 20
masked, kinds = sr.redact("AWS_SECRET_ACCESS_KEY=" + aws)
check("aws-assignment", masked == "AWS_SECRET_ACCESS_KEY=<hidden>" and "assignment" in kinds)

# GitHub fine-grained token: 22 + '_' + 59 characters after its prefix.
github_prefix = "github" + "_pat_"
github_head = "A1" * 11
github_tail = "B2" * 29 + "B"
github = github_prefix + github_head + "_" + github_tail
secret_shape("github-min", github, "github-token")
long_shape("github", github + "C3" * 5, "github-token")
short_shape("github", github_prefix + github_head + "_" + ("B2" * 29))

# GitLab PAT: 20-character token part; punctuation in the class is permitted.
gitlab_prefix = "gl" + "pat-"
gitlab_min = "A1" * 10
secret_shape("gitlab-min", gitlab_prefix + gitlab_min, "gitlab-token")
long_shape("gitlab", gitlab_prefix + gitlab_min + "C3" * 5, "gitlab-token")
short_shape("gitlab", gitlab_prefix + ("A1" * 9) + "A")

# Google API key: 35 characters after its case-sensitive prefix.
google_prefix = "AI" + "za"
google_min = "A1" * 17 + "A"
secret_shape("google-min", google_prefix + google_min, "google-api-key")
long_shape("google", google_prefix + google_min + "C3" * 5, "google-api-key")
short_shape("google", google_prefix + ("A1" * 17))

# Hugging Face token: public detector minimum 34 alphanumeric characters.
hf_prefix = "h" + "f_"
hf_min = "A1" * 17
secret_shape("huggingface-min", hf_prefix + hf_min, "huggingface-token")
long_shape("huggingface", hf_prefix + hf_min + "C3" * 5, "huggingface-token")
short_shape("huggingface", hf_prefix + ("A1" * 16) + "A")

# Stripe live secret and restricted keys: test both prefixes at the 20-character floor.
stripe_min = "A1" * 10
for label, prefix in (("stripe-sk", "sk_" + "live_"), ("stripe-rk", "rk_" + "live_")):
    secret_shape(label + "-min", prefix + stripe_min, "stripe-secret-key")
    long_shape(label, prefix + stripe_min + "C3" * 5, "stripe-secret-key")
    short_shape(label, prefix + ("A1" * 9) + "A")

# npm uses 36 characters; PyPI accepts 85 or more.
npm_prefix = "np" + "m_"
npm_min = "A1" * 18
secret_shape("npm-min", npm_prefix + npm_min, "npm-token")
long_shape("npm", npm_prefix + npm_min + "C3" * 5, "npm-token")
short_shape("npm", npm_prefix + ("A1" * 17) + "A")

pypi_prefix = "pyp" + "i-"
pypi_min = "A1" * 42 + "A"
secret_shape("pypi-min", pypi_prefix + pypi_min, "pypi-token")
long_shape("pypi", pypi_prefix + pypi_min + "C3" * 5, "pypi-token")
short_shape("pypi", pypi_prefix + ("A1" * 42))

# Presigned URLs and non-Bearer Authorization headers: only the value is masked.
sig = "S1g" * 6
masked, kinds = sr.redact("curl 'http://h.test/b/o?X-Amz-Signature=" + sig + "&Expires=1'")
check("url-signature", masked == "curl 'http://h.test/b/o?X-Amz-Signature=<hidden>&Expires=1'"
      and kinds == ["url-signature"])
akid = "AK" + "F4" * 7
masked, kinds = sr.redact("http://h.test/o?AWSAccessKeyId=" + akid + "&Signature=" + sig)
check("url-access-key", masked == "http://h.test/o?AWSAccessKeyId=<hidden>&Signature=<hidden>"
      and kinds == ["url-access-key", "url-signature"])
masked, kinds = sr.redact("-H 'Authorization: Basic " + sig + "'")
check("authorization-basic", masked == "-H 'Authorization: Basic <hidden>'"
      and kinds == ["authorization-header"])
short_shape("url-signature", "?Signature=" + "S1g" * 2 + "a")

# These are intentionally not secrets; every value and kind must remain unchanged.
keep = [
    'token = os.environ.get("DRSG_TOKEN")',
    "DRSG_TOKEN=change-me",
    "DRSG_TOKEN=<hidden>",
    "${API_KEY}",
    "$TOKEN",
    "secret_redact.py",
    "ALLOWED_COMMIT_HOOK_SHA256",
    "--forbidden-literals",
    "DRSG_L3_KEY_ENV=OPENAI_API_KEY",
    "942b4c807d9d86fe0a4f90933ba16c5c5905a874",
    "MONKEY=abc123",
    "?X-Amz-Signature=$SIG&Expires=1",
    "?Signature=${SIG}",
    "Authorization: Basic <token>",
]
for index, value in enumerate(keep):
    check("keep-%02d" % index, sr.redact(value) == (value, []))

if only and ran == 0:
    print("FAIL unknown-only-case")
    sys.exit(2)
print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ok == ran else 1)
PY

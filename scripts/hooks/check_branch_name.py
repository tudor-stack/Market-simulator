import subprocess
import sys
import re

branch = subprocess.check_output(["git", "branch", "--show-current"]).decode().strip()

if branch == "main":
    sys.exit(0)

pattern = r"^(feature|bugfix|perf|experiment|chore)/[0-9]+_[a-z0-9_]+$"

if re.match(pattern, branch):
    sys.exit(0)

print(f'Branch "{branch}" does not match convention.')
print(f'Expected: <type>/<number>_<name>')
print(f'Example:  feature/42_cancel_order_by_id')
sys.exit(1)

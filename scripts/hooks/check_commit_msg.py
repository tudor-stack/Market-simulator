import sys
import re

msg = open(sys.argv[1]).read().split("\n")[0]
pattern = r"^(feature|bugfix|perf|experiment|chore)/[0-9]+_[a-z0-9_]+:\s+.+"

if re.match(pattern, msg):
    sys.exit(0)

print(f'Bad commit message:')
print(f'  "{msg}"')
print(f'Expected format:')
print(f'  feature/42_cancel_order_by_id: your message here')
sys.exit(1)

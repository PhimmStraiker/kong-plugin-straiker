import yaml
from utils import add, fmt_line

def load_config(path="config.yaml"):
    with open(path) as f:
        return yaml.safe_load(f)

def main():
    cfg = load_config()
    total = add(cfg["quota"]["team_a"], cfg["quota"]["team_b"])
    print(fmt_line("total quota", total))

if __name__ == "__main__":
    main()

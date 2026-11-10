import json

from .data import build_database

if __name__ == "__main__":
    print(json.dumps(build_database(), ensure_ascii=False, indent=2))

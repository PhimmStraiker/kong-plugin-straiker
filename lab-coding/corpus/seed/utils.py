def add(a, b):
    return a + b

def fmt_line(label, value):
    return f"{label}: {value}"

def parse_token(raw):
    return raw.strip().split(":")[-1]

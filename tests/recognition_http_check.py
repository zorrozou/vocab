"""Run against the isolated UI fixture, never a production learning account."""
import json
from urllib.request import Request, urlopen
from urllib.error import HTTPError

BASE = "http://127.0.0.1:18765"
with urlopen(BASE + "/api/v1/__ui_fixture") as r:
    assert json.load(r) == {"fixture": "vocab-ui-isolated-v1"}


def assessment(body, status=200):
    request = Request(BASE + "/api/v1/placement/assessment",
                      data=json.dumps(body).encode(),
                      headers={"Content-Type": "application/json"})
    try:
        response = urlopen(request)
    except HTTPError as error:
        response = error
    with response:
        assert response.status == status, response.status
        return json.load(response)


excluded = list(range(2, 10988, 2))
result = assessment({"seed": "large-account", "exclude": excluded})
positions = [item["pos"] for item in result["words"]]
assert len(set(positions)) == 24
assert not set(positions).intersection(excluded)
assert [sum(lo <= p <= hi for p in positions) for lo, hi in
        [(1, 2000), (2001, 4000), (4001, 6000), (6001, 8000),
         (8001, 10000), (10001, 10987)]] == [4] * 6
for item in result["words"]:
    assert len(item["item_id"]) == 64
    assert sum(option["ok"] for option in item["options"]) == 1
for value in [True, 0, 10988, "123", 1.5]:
    assessment({"exclude": [value]}, 422)
assessment({"exclude": list(range(1, 10988))}, 503)
print("PASS full-bank holdout with 5,493 exclusions, invalid ranks and exhaustion")

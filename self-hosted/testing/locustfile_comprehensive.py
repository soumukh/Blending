import datetime
import os
import random

from locust import HttpUser, LoadTestShape, between, task


PRODUCTS = [
    "0PUK6V6EV0",
    "1YMWWN1N4O",
    "2ZYFJ3GM2N",
    "66VCHSJNUP",
    "6E92ZMYYFZ",
    "9SIQT8TOJO",
    "L9ECAV7KIM",
    "LS4PSXUNUM",
    "OLJCESPC7Z",
]

CURRENCIES = ["EUR", "USD", "JPY", "CAD", "GBP", "TRY"]


FULL_SCENARIOS = {
    "warmup_50": {"kind": "stages", "stages": [(300, 50, 10)]},
    "steady_200": {"kind": "stages", "stages": [(1500, 200, 10)]},
    "stress_ramp_500": {
        "kind": "stages",
        "stages": [
            (300, 100, 20),
            (900, 200, 25),
            (1350, 350, 35),
            (1800, 500, 50),
        ],
    },
    "spike_500": {
        "kind": "cycle",
        "total_duration": 1200,
        "cycle_duration": 300,
        "segments": [(60, 50, 50), (120, 500, 250), (300, 150, 75)],
    },
    "soak_250": {"kind": "stages", "stages": [(2700, 250, 25)]},
    "recovery_25": {"kind": "stages", "stages": [(600, 25, 10)]},
}

SMOKE_SCENARIOS = {
    "warmup_50": {"kind": "stages", "stages": [(60, 20, 10)]},
    "steady_200": {"kind": "stages", "stages": [(90, 50, 20)]},
    "stress_ramp_500": {
        "kind": "stages",
        "stages": [(45, 40, 20), (90, 70, 30), (120, 100, 40)],
    },
    "spike_500": {
        "kind": "cycle",
        "total_duration": 120,
        "cycle_duration": 60,
        "segments": [(15, 20, 20), (30, 100, 80), (60, 40, 30)],
    },
    "soak_250": {"kind": "stages", "stages": [(120, 60, 20)]},
    "recovery_25": {"kind": "stages", "stages": [(60, 15, 10)]},
}

COMPACT30_SCENARIOS = {
    "compact_warmup_100": {"kind": "stages", "stages": [(120, 100, 50)]},
    "compact_steady_350": {"kind": "stages", "stages": [(240, 350, 70)]},
    "compact_spike_700": {
        "kind": "cycle",
        "total_duration": 300,
        "cycle_duration": 300,
        "segments": [(60, 100, 100), (180, 700, 300), (300, 250, 125)],
    },
    "compact_faas_low_80": {"kind": "stages", "stages": [(210, 80, 40)]},
    "compact_dynamic_ramp_700": {
        "kind": "stages",
        "stages": [
            (120, 100, 50),
            (240, 350, 100),
            (360, 550, 150),
            (480, 700, 200),
        ],
    },
    "compact_recovery_50": {"kind": "stages", "stages": [(240, 50, 25)]},
}


def scenario_config():
    scenario = os.getenv("SCENARIO", "warmup_50").strip()
    profile = os.getenv("SUITE_PROFILE", "full").strip().lower()
    if profile == "smoke":
        scenarios = SMOKE_SCENARIOS
    elif profile == "compact30":
        scenarios = COMPACT30_SCENARIOS
    else:
        scenarios = FULL_SCENARIOS
    if scenario not in scenarios:
        known = ", ".join(sorted(scenarios))
        raise RuntimeError(f"unknown SCENARIO={scenario!r}; expected one of: {known}")
    return scenarios[scenario]


class GOBUser(HttpUser):
    wait_time = between(
        float(os.getenv("MIN_WAIT_SECONDS", "0.3")),
        float(os.getenv("MAX_WAIT_SECONDS", "1.5")),
    )

    def on_start(self):
        self.client.get("/", name="/")

    @task(10)
    def browse_home(self):
        self.client.get("/", name="/")

    @task(6)
    def browse_product(self):
        product = random.choice(PRODUCTS)
        self.client.get(f"/product/{product}", name="/product/[id]")

    @task(4)
    def currency_change(self):
        self.client.post(
            "/setCurrency",
            data={"currency_code": random.choice(CURRENCIES)},
            headers={"Referer": self.host + "/"},
            name="/setCurrency",
        )

    @task(4)
    def cart_flow(self):
        product = random.choice(PRODUCTS)
        self.client.get(f"/product/{product}", name="/product/[id]")
        self.client.post(
            "/cart",
            data={"product_id": product, "quantity": random.randint(1, 10)},
            name="/cart",
        )
        self.client.get("/cart", name="/cart")

    @task(3)
    def checkout_flow(self):
        product = random.choice(PRODUCTS)
        self.client.post(
            "/cart",
            data={"product_id": product, "quantity": random.randint(1, 3)},
            name="/cart",
        )
        next_year = datetime.datetime.now().year + 1
        self.client.post(
            "/cart/checkout",
            data={
                "email": f"load-{random.randint(1000, 9999)}@example.com",
                "street_address": "123 Main St",
                "zip_code": "10001",
                "city": "New York",
                "state": "NY",
                "country": "US",
                "credit_card_number": "4432801561520454",
                "credit_card_expiration_month": random.randint(1, 12),
                "credit_card_expiration_year": random.randint(next_year, next_year + 10),
                "credit_card_cvv": random.randint(100, 999),
            },
            name="/cart/checkout",
        )

    @task(2)
    def cart_read(self):
        self.client.get("/cart", name="/cart")


class ComprehensiveShape(LoadTestShape):
    def tick(self):
        config = scenario_config()
        run_time = self.get_run_time()

        if config["kind"] == "stages":
            for duration, users, spawn_rate in config["stages"]:
                if run_time < duration:
                    return users, spawn_rate
            return None

        if run_time >= config["total_duration"]:
            return None

        cycle_position = run_time % config["cycle_duration"]
        for upper_bound, users, spawn_rate in config["segments"]:
            if cycle_position < upper_bound:
                return users, spawn_rate

        return None

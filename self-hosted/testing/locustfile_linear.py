import datetime
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


class GOBUser(HttpUser):
    wait_time = between(1, 3)

    def on_start(self):
        self.client.get("/")

    @task(10)
    def browse(self):
        self.client.get("/")

    @task(5)
    def view_product(self):
        self.client.get(f"/product/{random.choice(PRODUCTS)}")

    @task(3)
    def add_to_cart(self):
        product = random.choice(PRODUCTS)
        self.client.get(f"/product/{product}")
        self.client.post(
            "/cart",
            data={
                "product_id": product,
                "quantity": random.randint(1, 10),
            },
        )

    @task(2)
    def checkout(self):
        product = random.choice(PRODUCTS)
        self.client.post(
            "/cart",
            data={
                "product_id": product,
                "quantity": 1,
            },
        )
        next_year = datetime.datetime.now().year + 1
        self.client.post(
            "/cart/checkout",
            data={
                "email": f"test-{random.randint(1000, 9999)}@example.com",
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
        )

    @task(3)
    def currencies(self):
        self.client.post(
            "/setCurrency",
            data={"currency_code": random.choice(CURRENCIES)},
            headers={"Referer": self.host + "/"},
        )

    @task(2)
    def view_cart(self):
        self.client.get("/cart")


class LinearShape(LoadTestShape):
    stages = [
        {"duration": 300, "users": 200, "spawn_rate": 10},
        {"duration": 1500, "users": 200, "spawn_rate": 10},
    ]

    def tick(self):
        run_time = self.get_run_time()

        for stage in self.stages:
            if run_time < stage["duration"]:
                return stage["users"], stage["spawn_rate"]

        return None


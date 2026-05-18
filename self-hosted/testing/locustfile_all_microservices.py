import datetime
import os
import random

from locust import HttpUser, between, task


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


def target_service() -> str:
    return os.getenv("TARGET_SERVICE", "frontend").strip().lower()


class AllMicroserviceUser(HttpUser):
    wait_time = between(
        float(os.getenv("MIN_WAIT_SECONDS", "0.05")),
        float(os.getenv("MAX_WAIT_SECONDS", "0.4")),
    )

    def on_start(self):
        self.client.get("/", name="/")

    def product_id(self) -> str:
        return random.choice(PRODUCTS)

    def browse_home(self):
        self.client.get("/", name="/")

    def browse_product(self):
        self.client.get(f"/product/{self.product_id()}", name="/product/[id]")

    def change_currency(self):
        self.client.post(
            "/setCurrency",
            data={"currency_code": random.choice(CURRENCIES)},
            headers={"Referer": self.host + "/"},
            name="/setCurrency",
        )

    def add_to_cart(self, quantity: int | None = None):
        product = self.product_id()
        self.client.get(f"/product/{product}", name="/product/[id]")
        self.client.post(
            "/cart",
            data={
                "product_id": product,
                "quantity": quantity if quantity is not None else random.randint(1, 10),
            },
            name="/cart",
        )

    def read_cart(self):
        self.client.get("/cart", name="/cart")

    def checkout(self):
        self.add_to_cart(quantity=random.randint(1, 3))
        next_year = datetime.datetime.now().year + 1
        self.client.post(
            "/cart/checkout",
            data={
                "email": f"load-{random.randint(100000, 999999)}@example.com",
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

    @task
    def service_dominant_flow(self):
        service = target_service()

        if service == "frontend":
            if random.random() < 0.7:
                self.browse_home()
            else:
                self.browse_product()
            return

        if service in {"productcatalogservice", "recommendationservice", "adservice"}:
            if random.random() < 0.8:
                self.browse_product()
            else:
                self.browse_home()
            return

        if service == "currencyservice":
            self.change_currency()
            if random.random() < 0.2:
                self.browse_home()
            return

        if service in {"cartservice", "redis-cart"}:
            if random.random() < 0.65:
                self.add_to_cart()
            else:
                self.read_cart()
            return

        if service in {
            "checkoutservice",
            "paymentservice",
            "emailservice",
            "shippingservice",
        }:
            if random.random() < 0.75:
                self.checkout()
            else:
                self.add_to_cart()
            return

        self.browse_home()

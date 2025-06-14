from locust import FastHttpUser, TaskSet, between, task
from faker import Faker
import random
import datetime

fake = Faker()

products = [
    '0PUK6V6EV0', '1YMWWN1N4O', '2ZYFJ3GM2N', '66VCHSJNUP',
    '6E92ZMYYFZ', '9SIQT8TOJO', 'L9ECAV7KIM', 'LS4PSXUNUM', 'OLJCESPC7Z'
]

class UserBehavior(TaskSet):
    def on_start(self):
        self.client.get("/")

    @task(1)
    def index(self):
        self.client.get("/")

    @task(2)
    def setCurrency(self):
        currencies = ['EUR', 'USD', 'JPY', 'CAD', 'GBP', 'TRY']
        self.client.post("/setCurrency", {'currency_code': random.choice(currencies)})

    @task(10)
    def browseProduct(self):
        self.client.get("/product/" + random.choice(products))

    @task(3)
    def viewCart(self):
        self.client.get("/cart")

    @task(2)
    def addToCart(self):
        product = random.choice(products)
        self.client.get("/product/" + product)
        self.client.post("/cart", {'product_id': product, 'quantity': random.randint(1, 10)})

    @task(1)
    def checkout(self):
        self.addToCart()  # Ensure cart has items
        current_year = datetime.datetime.now().year + 1
        self.client.post("/cart/checkout", {
            'email': fake.email(),
            'street_address': fake.street_address(),
            'zip_code': fake.zipcode(),
            'city': fake.city(),
            'state': fake.state_abbr(),
            'country': fake.country(),
            'credit_card_number': fake.credit_card_number(card_type="visa"),
            'credit_card_expiration_month': random.randint(1, 12),
            'credit_card_expiration_year': random.randint(current_year, current_year + 70),
            'credit_card_cvv': f"{random.randint(100, 999)}",
        })

class WebsiteUser(FastHttpUser):
    tasks = [UserBehavior]
    wait_time = between(1, 10)

# Linear increase via CLI: locust -f linear_locustfile.py --host=http://<frontend-ip> --users=100 --spawn-rate=1
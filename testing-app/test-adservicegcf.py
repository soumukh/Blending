#!/usr/bin/python
#
# Custom Locust file to test GCF-powered adservice in Online Boutique
# Focuses on ad-related endpoints with stable traffic
#

import random
from locust import FastHttpUser, TaskSet, between
from faker import Faker
import datetime

fake = Faker()

# Product IDs from Online Boutique
products = [
    '0PUK6V6EV0', '1YMWWN1N4O', '2ZYFJ3GM2N', '66VCHSJNUP',
    '6E92ZMYYFZ', '9SIQT8TOJO', 'L9ECAV7KIM', 'LS4PSXUNUM', 'OLJCESPC7Z'
]

# Currencies from frontend whitelist
currencies = ['USD', 'EUR', 'CAD', 'JPY', 'GBP', 'TRY']

def index(l):
    """Load homepage (triggers adservice GCF)."""
    l.client.get("/")

def browseProduct(l):
    """Browse product page (triggers adservice GCF)."""
    product = random.choice(products)
    l.client.get("/product/" + product)

def setCurrency(l):
    """Change currency (triggers currencyservice GCF)."""
    currency = random.choice(currencies)
    l.client.post("/setCurrency", {'currency_code': currency})

def viewCart(l):
    """View cart (includes adservice GCF via frontend)."""
    l.client.get("/cart")

def addToCart(l):
    """Add product to cart (visits product page, triggers adservice GCF)."""
    product = random.choice(products)
    l.client.get("/product/" + product)
    l.client.post("/cart", {
        'product_id': product,
        'quantity': random.randint(1, 3)  # Stable, low quantity
    })

def checkout(l):
    """Checkout (triggers currencyservice GCF via checkoutservice)."""
    addToCart(l)
    current_year = datetime.datetime.now().year + 1
    l.client.post("/cart/checkout", {
        'email': fake.email(),
        'street_address': fake.street_address(),
        'zip_code': fake.zipcode(),
        'city': fake.city(),
        'state': fake.state_abbr(),
        'country': fake.country(),
        'credit_card_number': fake.credit_card_number(card_type="visa"),
        'credit_card_expiration_month': random.randint(1, 12),
        'credit_card_expiration_year': random.randint(current_year, current_year + 5),
        'credit_card_cvv': f"{random.randint(100, 999)}",
    })

class AdServiceTestBehavior(TaskSet):
    def on_start(self):
        """Start with homepage and a currency."""
        index(self)
        setCurrency(self)

    # Task weights: Focus on adservice, stable load
    tasks = {
        index: 3,          # Homepage ads (GCF adservice)
        browseProduct: 5,  # Product page ads (GCF adservice, highest weight)
        setCurrency: 2,    # Currency changes (GCF currencyservice)
        addToCart: 2,      # Cart adds (includes product page ads)
        viewCart: 2,       # Cart view (GCF adservice)
        checkout: 1        # Checkout (GCF currencyservice)
    }

class AdServiceTestUser(FastHttpUser):
    tasks = [AdServiceTestBehavior]
    wait_time = between(2, 5)  # Steady wait, no bursts
#!/usr/bin/python
#
# Custom Locust file to test GCF currency conversion in Online Boutique
# Focuses on currency changes, product browsing, and checkout
#

import random
from locust import FastHttpUser, TaskSet, between
from faker import Faker
import datetime

fake = Faker()

# Product IDs from the Online Boutique demo
products = [
    '0PUK6V6EV0',
    '1YMWWN1N4O',
    '2ZYFJ3GM2N',
    '66VCHSJNUP',
    '6E92ZMYYFZ',
    '9SIQT8TOJO',
    'L9ECAV7KIM',
    'LS4PSXUNUM',
    'OLJCESPC7Z'
]

# Currencies supported by your GCF (from currency_conversion.json, filtered by frontend whitelist)
currencies = ['USD', 'EUR', 'CAD', 'JPY', 'GBP', 'TRY']

def index(l):
    """Load the homepage."""
    l.client.get("/")

def setCurrency(l):
    """Change the user's currency to trigger GCF conversion."""
    currency = random.choice(currencies)
    l.client.post("/setCurrency", {'currency_code': currency})
    # Log the currency change for debugging
    print(f"Set currency to {currency}")

def browseProduct(l):
    """Browse a product page to trigger currency conversion in frontend."""
    product = random.choice(products)
    l.client.get("/product/" + product)

def viewCart(l):
    """View the cart with converted prices."""
    l.client.get("/cart")

def addToCart(l):
    """Add a random product to the cart."""
    product = random.choice(products)
    l.client.get("/product/" + product)  # Visit product page first
    l.client.post("/cart", {
        'product_id': product,
        'quantity': random.randint(1, 5)  # Smaller quantities for faster checkout
    })

def checkout(l):
    """Checkout to trigger currency conversion in checkoutservice."""
    addToCart(l)  # Ensure cart has items
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
        'credit_card_expiration_year': random.randint(current_year, current_year + 10),
        'credit_card_cvv': f"{random.randint(100, 999)}",
    })

class CurrencyTestBehavior(TaskSet):
    def on_start(self):
        """Start with homepage and set an initial currency."""
        index(self)
        setCurrency(self)

    # Task weights: Emphasize currency changes and conversions
    tasks = {
        setCurrency: 5,      # Frequent currency switches to hit GCF
        browseProduct: 3,    # Product views to convert prices
        addToCart: 2,        # Add items to cart
        viewCart: 2,         # View cart with converted prices
        checkout: 1          # Checkout to test checkoutservice
    }

class CurrencyTestUser(FastHttpUser):
    tasks = [CurrencyTestBehavior]
    wait_time = between(1, 5)  # Faster wait times to increase load

import functions_framework
import json
from logger import getJSONLogger
from jinja2 import Environment, FileSystemLoader, select_autoescape, TemplateError

logger = getJSONLogger('emailservice-gcf')
env = Environment(
    loader=FileSystemLoader('templates'),
    autoescape=select_autoescape(['html', 'xml'])
)
template = env.get_template('confirmation.html')

@functions_framework.http
def send_email(request):
    if request.method != "POST":
        return "Method not allowed", 405
    
    request_json = request.get_json(silent=True)
    if not request_json or "email" not in request_json:
        return "Invalid request: 'email' required", 400
    
    email = request_json["email"]
    order = request_json.get("order", {})
    
    logger.info(f"A request to send order confirmation email to {email} has been received.")
    
    try:
        confirmation = template.render(order=order)
    except TemplateError as err:
        logger.error(f"Error rendering template: {str(err)}")
        return "Error preparing confirmation email", 500
    
    logger.info("Generated email content:")
    logger.info(confirmation)
    
    return {}, 200
FROM public.ecr.aws/lambda/python:3.11

# Install dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy code
COPY app.py .

# Lambda entrypoint
CMD [ "app.lambda_handler" ]
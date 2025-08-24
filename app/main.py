import os
import sys
import base64
import json
from functools import wraps

import functions_framework
from flask import request
from google import genai
from google.genai import types
from google.cloud import storage
import requests

# --- GCS Client ---
def _get_prompt_from_gcs(bucket_name, file_path):
    """Downloads a prompt file from GCS."""
    try:
        storage_client = storage.Client()
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(file_path)
        prompt_content = blob.download_as_text()
        return prompt_content
    except Exception as e:
        print(f"Error downloading from GCS: {e}", file=sys.stderr)
        return None

# --- GCP Vertex AI (Gemini) Client ---
def generate_response_with_gemini(issue_content):
    """Generates a response using the Gemini model."""
    try:
        # The google-genai library uses the GOOGLE_API_KEY environment variable.
        # On Cloud Functions, this is automatically set up.

        project_id = os.environ.get("GCP_PROJECT_ID")
        location = os.environ.get("GEMINI_REGION") # Use the dedicated Gemini region
        model_name = os.environ.get("GEMINI_MODEL_NAME")
        
        # Get system prompt from GCS
        bucket_name = os.environ.get("PROMPT_GCS_BUCKET_NAME")
        file_path = os.environ.get("SYSTEM_PROMPT_GCS_FILE_PATH")
        system_prompt = _get_prompt_from_gcs(bucket_name, file_path)

        if not system_prompt:
            print("Error: System prompt could not be loaded from GCS.", file=sys.stderr)
            return None
        client = genai.Client(
            vertexai=True, project=project_id, location=location
        )

        # Pass the entire issue content as a JSON string
        content_as_json = json.dumps(issue_content, indent=2, ensure_ascii=False)

        prompt = f"""{system_prompt}

## 課題情報 (JSON)
```json
{content_as_json}
```
"""
        
        response = client.models.generate_content(
            model=model_name, contents=prompt
        )
        return response.text

    except Exception as e:
        print(f"Error calling Gemini API: {e}", file=sys.stderr)
        return None

# --- Backlog API Client ---
def post_comment_to_backlog(issue_key, comment):
    """Posts a comment to a Backlog issue."""
    try:
        base_url = os.environ.get("BACKLOG_SPACE_URL")
        api_key = os.environ.get("BACKLOG_API_KEY")
        
        api_url = f"{base_url}/api/v2/issues/{issue_key}/comments"
        params = {"apiKey": api_key}
        payload = {"content": comment}

        response = requests.post(api_url, params=params, data=payload)
        response.raise_for_status()  # Raise an exception for bad status codes
        
        print(f"Successfully posted comment to {issue_key}.")
        return True

    except requests.exceptions.RequestException as e:
        print(f"Error posting to Backlog: {e}", file=sys.stderr)
        return False

# --- Authentication ---
def check_basic_auth(request):
    """Checks for basic authentication."""
    # In API Gateway, the original Authorization header is passed in this header.
    auth_header = request.headers.get('X-Forwarded-Authorization')
    if not auth_header:
        return ("Authentication Required", 401)

    try:
        auth_type, auth_value = auth_header.split(None, 1)
        if auth_type.lower() != 'basic':
            return ("Unsupported authentication type", 401)
        
        decoded_bytes = base64.b64decode(auth_value)
        decoded_string = decoded_bytes.decode('utf-8')
        username, password = decoded_string.split(':', 1)

    except (ValueError, TypeError) as e:
        print(f"Error decoding auth header: {e}", file=sys.stderr)
        return ("Invalid Authorization header", 401)

    expected_username = os.environ.get("BASIC_AUTH_USERNAME")
    expected_password = os.environ.get("BASIC_AUTH_PASSWORD")

    if not (username == expected_username and password == expected_password):
        return ("Authentication Required", 401)
    
    return None

# --- Webhook Endpoint ---
@functions_framework.http
def webhook(request):
    """Handles incoming webhook from Backlog."""
    auth_error = check_basic_auth(request)
    if auth_error:
        message, status_code = auth_error
        return ({"message": message}, status_code)

    if not request.is_json:
        return ({"message": "Request must be JSON"}, 400)

    data = request.get_json()
    print(f"Received data: {data}")

    # We only process issue creation events (type: 1)
    if data.get("type") != 1:
        return ({"message": "Not an issue creation event."}, 200)

    content = data.get("content", {})
    issue_key = content.get("id")
    
    if not issue_key:
        return ({"message": "Missing issue key."}, 200)

    # Generate response from Gemini, passing the whole content
    gemini_response = generate_response_with_gemini(content)
    if not gemini_response:
        return ({"message": "Failed to get response from Gemini."}, 500)

    # Post comment to Backlog
    success = post_comment_to_backlog(issue_key, gemini_response)
    if not success:
        return ({"message": "Failed to post comment to Backlog."}, 500)

    return ({"status": "success"}, 200)

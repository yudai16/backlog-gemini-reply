output "api_gateway_url" {
  description = "The default hostname of the API Gateway."
  value       = "https://${google_api_gateway_gateway.default.default_hostname}"
}

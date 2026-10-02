class ValidationError(Exception):
    pass


def validate(instance: dict, schema: dict) -> None:
    for field in schema.get("required", []):
        if instance.get(field) in (None, ""):
            raise ValidationError(f"{field} is required")

    properties = schema.get("properties", {})
    for key, value in instance.items():
        definition = properties.get(key)
        if definition is None:
            raise ValidationError(f"{key} is not allowed")
        expected_type = definition.get("type")
        if expected_type == "string" and not isinstance(value, str):
            raise ValidationError(f"{key} must be a string")
        if expected_type == "object" and not isinstance(value, dict):
            raise ValidationError(f"{key} must be an object")
        if "enum" in definition and value not in definition["enum"]:
            raise ValidationError(f"{key} must be one of {', '.join(definition['enum'])}")

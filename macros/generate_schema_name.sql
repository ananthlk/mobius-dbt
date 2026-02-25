{% macro generate_schema_name(custom_schema_name, node) %}
{%- if custom_schema_name and ('mobius_medicaid' in custom_schema_name or 'landing_medicaid' in custom_schema_name) -%}
    {{ custom_schema_name }}
{%- else -%}
    {{ default__generate_schema_name(custom_schema_name, node) }}
{%- endif -%}
{% endmacro %}

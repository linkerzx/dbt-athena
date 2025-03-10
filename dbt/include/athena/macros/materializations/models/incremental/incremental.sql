{% materialization incremental, adapter='athena' -%}

  {% set raw_strategy = config.get('incremental_strategy') or 'insert_overwrite' %}
  {% set table_type = config.get('table_type', default='hive') | lower %}
  {% set strategy = validate_get_incremental_strategy(raw_strategy, table_type) %}
  {% set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change'), default='ignore') %}

  {% set lf_tags_config = config.get('lf_tags_config') %}
  {% set lf_grants = config.get('lf_grants') %}
  {% set partitioned_by = config.get('partitioned_by') %}
  {% set target_relation = this.incorporate(type='table') %}
  {% set existing_relation = load_relation(this) %}
  {% set tmp_relation = make_temp_relation(this) %}

  -- If no partitions are used with insert_overwrite, we fall back to append mode.
  {% if partitioned_by is none and strategy == 'insert_overwrite' %}
    {% set strategy = 'append' %}
  {% endif %}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  -- `BEGIN` happens here:
  {{ run_hooks(pre_hooks, inside_transaction=True) }}

  {% set to_drop = [] %}
  {% if existing_relation is none %}
    {% set query_result = safe_create_table_as(False, target_relation, sql) -%}
    {% set build_sql = "select '{{ query_result }}'" -%}
  {% elif existing_relation.is_view or should_full_refresh() %}
    {% do drop_relation(existing_relation) %}
    {% set query_result = safe_create_table_as(False, target_relation, sql) -%}
    {% set build_sql = "select '{{ query_result }}'" -%}
  {% elif partitioned_by is not none and strategy == 'insert_overwrite' %}
    {% set tmp_relation = make_temp_relation(target_relation) %}
    {% if tmp_relation is not none %}
      {% do drop_relation(tmp_relation) %}
    {% endif %}
    {% set query_result = safe_create_table_as(True, tmp_relation, sql) -%}
    {% do delete_overlapping_partitions(target_relation, tmp_relation, partitioned_by) %}
    {% set build_sql = incremental_insert(on_schema_change, tmp_relation, target_relation, existing_relation) %}
    {% do to_drop.append(tmp_relation) %}
  {% elif strategy == 'append' %}
    {% set tmp_relation = make_temp_relation(target_relation) %}
    {% if tmp_relation is not none %}
      {% do drop_relation(tmp_relation) %}
    {% endif %}
    {% set query_result = safe_create_table_as(True, tmp_relation, sql) -%}
    {% set build_sql = incremental_insert(on_schema_change, tmp_relation, target_relation, existing_relation) %}
    {% do to_drop.append(tmp_relation) %}
  {% elif strategy == 'merge' and table_type == 'iceberg' %}
    {% set unique_key = config.get('unique_key') %}
    {% set incremental_predicates = config.get('incremental_predicates') %}
    {% set delete_condition = config.get('delete_condition') %}
    {% set empty_unique_key -%}
      Merge strategy must implement unique_key as a single column or a list of columns.
    {%- endset %}
    {% if unique_key is none %}
      {% do exceptions.raise_compiler_error(empty_unique_key) %}
    {% endif %}
    {% if incremental_predicates is not none %}
      {% set inc_predicates_not_list -%}
        Merge strategy must implement incremental_predicates as a list of predicates.
      {%- endset %}
      {% if not adapter.is_list(incremental_predicates) %}
        {% do exceptions.raise_compiler_error(inc_predicates_not_list) %}
      {% endif %}
    {% endif %}
    {% set tmp_relation = make_temp_relation(target_relation) %}
    {% if tmp_relation is not none %}
      {% do drop_relation(tmp_relation) %}
    {% endif %}
    {% set query_result = safe_create_table_as(True, tmp_relation, sql) -%}
    {% set build_sql = iceberg_merge(on_schema_change, tmp_relation, target_relation, unique_key, incremental_predicates, existing_relation, delete_condition) %}
    {% do to_drop.append(tmp_relation) %}
  {% endif %}

  {% call statement("main") %}
    {{ build_sql }}
  {% endcall %}

  -- set table properties
  {% if not to_drop and table_type != 'iceberg' %}
    {{ set_table_classification(target_relation) }}
  {% endif %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  -- `COMMIT` happens here
  {% do adapter.commit() %}

  {% for rel in to_drop %}
    {% do drop_relation(rel) %}
  {% endfor %}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

  {% if lf_tags_config is not none %}
    {{ adapter.add_lf_tags(target_relation, lf_tags_config) }}
  {% endif %}

  {% if lf_grants is not none %}
    {{ adapter.apply_lf_grants(target_relation, lf_grants) }}
  {% endif %}

  {% do persist_docs(target_relation, model) %}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}

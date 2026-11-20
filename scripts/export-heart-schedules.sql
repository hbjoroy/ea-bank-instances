SELECT COALESCE(json_agg(plan ORDER BY plan.name), '[]'::json)
FROM (
    SELECT s.name, s.definition_namespace, s.definition_name,
           s.definition_version, s.enabled, s.schedule_type,
           COALESCE((
               SELECT json_agg(p.name ORDER BY p.name)
               FROM admin.schedule_dependencies d
               JOIN admin.schedules p ON p.id = d.depends_on
               WHERE d.schedule_id = s.id
           ), '[]'::json) AS dependencies
    FROM admin.schedules s
) AS plan;




SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."add_correction_type_value"("new_value" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.check_constraints
    WHERE constraint_name = 'climb_corrections_correction_type_check'
    AND check_definition LIKE '%' || new_value || '%'
  ) THEN
    ALTER TABLE climb_corrections DROP CONSTRAINT climb_corrections_correction_type_check;
    ALTER TABLE climb_corrections ADD CONSTRAINT climb_corrections_correction_type_check
      CHECK (correction_type IN ('location', 'name', 'line', 'grade', 'removal'));
  END IF;
END;
$$;


ALTER FUNCTION "public"."add_correction_type_value"("new_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_submission_collaborator_invite"("p_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
  invite_row public.submission_collaborator_invites%ROWTYPE;
  image_owner_id UUID;
  inserted_count INTEGER := 0;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_token IS NULL THEN
    RAISE EXCEPTION 'Invite token is required';
  END IF;

  SELECT *
  INTO invite_row
  FROM public.submission_collaborator_invites
  WHERE token = p_token
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invite not found';
  END IF;

  IF invite_row.expires_at IS NOT NULL AND invite_row.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Invite has expired';
  END IF;

  IF invite_row.max_uses IS NOT NULL AND invite_row.used_count >= invite_row.max_uses THEN
    RAISE EXCEPTION 'Invite has reached max uses';
  END IF;

  SELECT i.created_by
  INTO image_owner_id
  FROM public.images i
  WHERE i.id = invite_row.image_id;

  IF image_owner_id IS NULL THEN
    RAISE EXCEPTION 'Submission owner not found';
  END IF;

  IF image_owner_id = current_user_id THEN
    RETURN jsonb_build_object(
      'image_id', invite_row.image_id,
      'already_owner', true,
      'already_collaborator', false,
      'added', false
    );
  END IF;

  INSERT INTO public.submission_collaborators (image_id, user_id, role, created_by)
  VALUES (invite_row.image_id, current_user_id, 'editor', invite_row.created_by)
  ON CONFLICT (image_id, user_id) DO NOTHING;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;

  IF inserted_count > 0 THEN
    UPDATE public.submission_collaborator_invites
    SET used_count = used_count + 1
    WHERE id = invite_row.id;
  END IF;

  RETURN jsonb_build_object(
    'image_id', invite_row.image_id,
    'already_owner', false,
    'already_collaborator', inserted_count = 0,
    'added', inserted_count > 0
  );
END;
$$;


ALTER FUNCTION "public"."claim_submission_collaborator_invite"("p_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_orphan_route_uploads"("max_age" interval DEFAULT '72:00:00'::interval, "max_delete" integer DEFAULT 300) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  deleted_count INTEGER := 0;
BEGIN
  WITH candidates AS (
    SELECT o.name
    FROM storage.objects o
    LEFT JOIN public.images i
      ON i.storage_bucket = o.bucket_id
     AND i.storage_path = o.name
    WHERE o.bucket_id = 'route-uploads'
      AND i.id IS NULL
      AND o.created_at < NOW() - max_age
    ORDER BY o.created_at ASC
    LIMIT GREATEST(max_delete, 0)
  ), deleted AS (
    DELETE FROM storage.objects o
    USING candidates c
    WHERE o.bucket_id = 'route-uploads'
      AND o.name = c.name
    RETURNING 1
  )
  SELECT COUNT(*) INTO deleted_count FROM deleted;

  RETURN deleted_count;
END;
$$;


ALTER FUNCTION "public"."cleanup_orphan_route_uploads"("max_age" interval, "max_delete" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."climbs_recompute_crag_location_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.crag_id IS NOT NULL THEN
      PERFORM public.recompute_crag_location(NEW.crag_id);
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.crag_id IS NOT NULL AND OLD.crag_id <> NEW.crag_id THEN
      PERFORM public.recompute_crag_location(OLD.crag_id);
    END IF;
    IF NEW.crag_id IS NOT NULL AND (OLD.latitude IS DISTINCT FROM NEW.latitude OR OLD.longitude IS DISTINCT FROM NEW.longitude OR OLD.crag_id IS DISTINCT FROM NEW.crag_id) THEN
      PERFORM public.recompute_crag_location(NEW.crag_id);
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.crag_id IS NOT NULL THEN
      PERFORM public.recompute_crag_location(OLD.crag_id);
    END IF;
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."climbs_recompute_crag_location_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_submission_routes_atomic"("p_image_id" "uuid", "p_crag_id" "uuid", "p_route_type" "text", "p_routes" "jsonb") RETURNS TABLE("climb_id" "uuid", "name" "text", "grade" "text")
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
  route_item JSONB;
  route_name TEXT;
  route_grade TEXT;
  route_slug TEXT;
  route_description TEXT;
  route_points JSONB;
  route_sequence_order INTEGER;
  route_image_width INTEGER;
  route_image_height INTEGER;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'Image ID is required';
  END IF;

  IF p_route_type IS NULL OR btrim(p_route_type) = '' THEN
    RAISE EXCEPTION 'Route type is required';
  END IF;

  IF p_routes IS NULL OR jsonb_typeof(p_routes) <> 'array' OR jsonb_array_length(p_routes) = 0 THEN
    RAISE EXCEPTION 'At least one route is required';
  END IF;

  FOR route_item IN
    SELECT value FROM jsonb_array_elements(p_routes)
  LOOP
    route_name := btrim(COALESCE(route_item->>'name', ''));
    route_grade := COALESCE(route_item->>'grade', '');
    route_slug := NULLIF(btrim(COALESCE(route_item->>'slug', '')), '');
    route_description := NULLIF(btrim(COALESCE(route_item->>'description', '')), '');
    route_points := route_item->'points';

    IF route_name = '' THEN
      RAISE EXCEPTION 'Route name is required';
    END IF;

    IF route_grade = '' THEN
      RAISE EXCEPTION 'Route grade is required';
    END IF;

    IF route_points IS NULL OR jsonb_typeof(route_points) <> 'array' OR jsonb_array_length(route_points) < 2 THEN
      RAISE EXCEPTION 'Route points must contain at least 2 points';
    END IF;

    BEGIN
      route_sequence_order := (route_item->>'sequence_order')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Route sequence_order must be a valid integer';
    END;

    BEGIN
      route_image_width := (route_item->>'image_width')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Route image_width must be a valid integer';
    END;

    BEGIN
      route_image_height := (route_item->>'image_height')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Route image_height must be a valid integer';
    END;

    INSERT INTO public.climbs (
      name,
      slug,
      grade,
      description,
      route_type,
      status,
      user_id,
      crag_id
    )
    VALUES (
      route_name,
      route_slug,
      route_grade,
      route_description,
      p_route_type,
      'approved',
      current_user_id,
      p_crag_id
    )
    RETURNING climbs.id, climbs.name, climbs.grade
    INTO climb_id, name, grade;

    INSERT INTO public.route_lines (
      image_id,
      climb_id,
      points,
      color,
      sequence_order,
      image_width,
      image_height
    )
    VALUES (
      p_image_id,
      climb_id,
      route_points,
      'red',
      route_sequence_order,
      route_image_width,
      route_image_height
    );

    RETURN NEXT;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."create_submission_routes_atomic"("p_image_id" "uuid", "p_crag_id" "uuid", "p_route_type" "text", "p_routes" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_unified_submission_atomic"("p_crag_id" "uuid", "p_primary_image" "jsonb", "p_supplementary_images" "jsonb"[], "p_routes" "jsonb", "p_route_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
  created_image_id UUID;
  created_climb_id UUID;
  created_route_line_id UUID;
  created_crag_image_id UUID;
  route_item JSONB;
  supplementary_item JSONB;
  route_name TEXT;
  route_grade TEXT;
  route_slug TEXT;
  route_description TEXT;
  route_points JSONB;
  route_sequence_order INTEGER;
  route_image_width INTEGER;
  route_image_height INTEGER;
  primary_url TEXT;
  primary_storage_bucket TEXT;
  primary_storage_path TEXT;
  primary_face_directions JSONB;
  created_climb_ids UUID[];
  created_route_line_ids UUID[];
  created_crag_image_ids UUID[];
BEGIN
  created_climb_ids := ARRAY[]::UUID[];
  created_route_line_ids := ARRAY[]::UUID[];
  created_crag_image_ids := ARRAY[]::UUID[];

  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_crag_id IS NULL THEN
    RAISE EXCEPTION 'Crag ID is required';
  END IF;

  IF p_primary_image IS NULL OR jsonb_typeof(p_primary_image) <> 'object' THEN
    RAISE EXCEPTION 'Primary image payload is required';
  END IF;

  IF p_route_type IS NULL OR btrim(p_route_type) = '' THEN
    RAISE EXCEPTION 'Route type is required';
  END IF;

  IF p_routes IS NULL OR jsonb_typeof(p_routes) <> 'array' OR jsonb_array_length(p_routes) = 0 THEN
    RAISE EXCEPTION 'At least one route is required';
  END IF;

  primary_url := NULLIF(btrim(COALESCE(p_primary_image->>'url', '')), '');
  primary_storage_bucket := NULLIF(btrim(COALESCE(p_primary_image->>'storage_bucket', '')), '');
  primary_storage_path := NULLIF(btrim(COALESCE(p_primary_image->>'storage_path', '')), '');
  primary_face_directions := COALESCE(p_primary_image->'face_directions', '[]'::jsonb);

  IF primary_url IS NULL THEN
    RAISE EXCEPTION 'Primary image url is required';
  END IF;

  IF primary_storage_bucket IS NULL THEN
    RAISE EXCEPTION 'Primary image storage_bucket is required';
  END IF;

  IF primary_storage_path IS NULL THEN
    RAISE EXCEPTION 'Primary image storage_path is required';
  END IF;

  IF jsonb_typeof(primary_face_directions) <> 'array' OR jsonb_array_length(primary_face_directions) = 0 THEN
    RAISE EXCEPTION 'Primary image face_directions must be a non-empty array';
  END IF;

  INSERT INTO public.images (
    url,
    storage_bucket,
    storage_path,
    latitude,
    longitude,
    capture_date,
    face_direction,
    face_directions,
    crag_id,
    width,
    height,
    natural_width,
    natural_height,
    created_by
  )
  VALUES (
    primary_url,
    primary_storage_bucket,
    primary_storage_path,
    NULLIF(p_primary_image->>'image_lat', '')::NUMERIC,
    NULLIF(p_primary_image->>'image_lng', '')::NUMERIC,
    NULLIF(p_primary_image->>'capture_date', '')::TIMESTAMPTZ,
    p_primary_image->'face_directions'->>0,
    ARRAY(SELECT jsonb_array_elements_text(p_primary_image->'face_directions')),
    p_crag_id,
    NULLIF(p_primary_image->>'width', '')::INTEGER,
    NULLIF(p_primary_image->>'height', '')::INTEGER,
    NULLIF(p_primary_image->>'natural_width', '')::INTEGER,
    NULLIF(p_primary_image->>'natural_height', '')::INTEGER,
    current_user_id
  )
  RETURNING id INTO created_image_id;

  IF p_supplementary_images IS NOT NULL THEN
    FOREACH supplementary_item IN ARRAY p_supplementary_images
    LOOP
      IF supplementary_item IS NULL OR jsonb_typeof(supplementary_item) <> 'object' THEN
        RAISE EXCEPTION 'Each supplementary image must be a JSON object';
      END IF;

      IF NULLIF(btrim(COALESCE(supplementary_item->>'url', '')), '') IS NULL THEN
        RAISE EXCEPTION 'Supplementary image url is required';
      END IF;

      INSERT INTO public.crag_images (
        crag_id,
        url,
        width,
        height,
        source_image_id,
        linked_image_id
      )
      VALUES (
        p_crag_id,
        btrim(supplementary_item->>'url'),
        NULLIF(supplementary_item->>'width', '')::INTEGER,
        NULLIF(supplementary_item->>'height', '')::INTEGER,
        created_image_id,
        NULL
      )
      RETURNING id INTO created_crag_image_id;

      created_crag_image_ids := array_append(created_crag_image_ids, created_crag_image_id);
    END LOOP;
  END IF;

  FOR route_item IN
    SELECT value FROM jsonb_array_elements(p_routes)
  LOOP
    route_name := btrim(COALESCE(route_item->>'name', ''));
    route_grade := COALESCE(route_item->>'grade', '');
    route_slug := NULLIF(btrim(COALESCE(route_item->>'slug', '')), '');
    route_description := NULLIF(btrim(COALESCE(route_item->>'description', '')), '');
    route_points := route_item->'points';

    IF route_name = '' THEN
      RAISE EXCEPTION 'Route name is required';
    END IF;

    IF route_grade = '' THEN
      RAISE EXCEPTION 'Route grade is required';
    END IF;

    IF route_points IS NULL OR jsonb_typeof(route_points) <> 'array' OR jsonb_array_length(route_points) < 2 THEN
      RAISE EXCEPTION 'Route points must contain at least 2 points';
    END IF;

    BEGIN
      route_sequence_order := (route_item->>'sequence_order')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Route sequence_order must be a valid integer';
    END;

    BEGIN
      route_image_width := (route_item->>'image_width')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Route image_width must be a valid integer';
    END;

    BEGIN
      route_image_height := (route_item->>'image_height')::INTEGER;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Route image_height must be a valid integer';
    END;

    INSERT INTO public.climbs (
      name,
      slug,
      grade,
      description,
      route_type,
      status,
      user_id,
      crag_id
    )
    VALUES (
      route_name,
      route_slug,
      route_grade,
      route_description,
      p_route_type,
      'approved',
      current_user_id,
      p_crag_id
    )
    RETURNING id INTO created_climb_id;

    created_climb_ids := array_append(created_climb_ids, created_climb_id);

    INSERT INTO public.route_lines (
      image_id,
      climb_id,
      points,
      color,
      sequence_order,
      image_width,
      image_height
    )
    VALUES (
      created_image_id,
      created_climb_id,
      route_points,
      'red',
      route_sequence_order,
      route_image_width,
      route_image_height
    )
    RETURNING id INTO created_route_line_id;

    created_route_line_ids := array_append(created_route_line_ids, created_route_line_id);
  END LOOP;

  RETURN jsonb_build_object(
    'image_id', created_image_id,
    'crag_id', p_crag_id,
    'climb_ids', to_jsonb(created_climb_ids),
    'route_line_ids', to_jsonb(created_route_line_ids),
    'crag_image_ids', to_jsonb(created_crag_image_ids),
    'climbs_created', COALESCE(array_length(created_climb_ids, 1), 0),
    'route_lines_created', COALESCE(array_length(created_route_line_ids, 1), 0),
    'supplementary_created', COALESCE(array_length(created_crag_image_ids, 1), 0)
  );
END;
$$;


ALTER FUNCTION "public"."create_unified_submission_atomic"("p_crag_id" "uuid", "p_primary_image" "jsonb", "p_supplementary_images" "jsonb"[], "p_routes" "jsonb", "p_route_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_empty_crag"("target_crag_id" "uuid", "grace_period" interval DEFAULT '24:00:00'::interval) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  deleted_count integer := 0;
  crag_exists boolean := false;
BEGIN
  IF target_crag_id IS NULL THEN
    RETURN false;
  END IF;

  -- Check if crag exists and meets deletion criteria
  SELECT EXISTS (
    SELECT 1 FROM public.crags c
    WHERE c.id = target_crag_id
      AND c.created_at < now() - grace_period
      AND NOT EXISTS (
        SELECT 1 FROM public.images i WHERE i.crag_id = c.id
      )
  ) INTO crag_exists;

  IF crag_exists THEN
    -- Delete from places table first (sync trigger doesn't fire from function)
    DELETE FROM public.places WHERE id = target_crag_id AND type = 'crag';
    
    -- Delete the crag (this will cascade delete climbs)
    DELETE FROM public.crags WHERE id = target_crag_id;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
  END IF;

  RETURN deleted_count > 0;
END;
$$;


ALTER FUNCTION "public"."delete_empty_crag"("target_crag_id" "uuid", "grace_period" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_empty_crags"("grace_period" interval DEFAULT '24:00:00'::interval) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  deleted_count integer := 0;
BEGIN
  DELETE FROM public.crags c
  WHERE c.created_at < now() - grace_period
    AND NOT EXISTS (
      SELECT 1
      FROM public.images i
      WHERE i.crag_id = c.id
    );

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;


ALTER FUNCTION "public"."delete_empty_crags"("grace_period" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_comment_soft_delete_only"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  IF OLD.target_type <> NEW.target_type
     OR OLD.target_id <> NEW.target_id
     OR OLD.author_id IS DISTINCT FROM NEW.author_id
     OR OLD.body <> NEW.body
     OR OLD.category <> NEW.category
     OR OLD.created_at <> NEW.created_at THEN
    RAISE EXCEPTION 'Comments cannot be edited';
  END IF;

  IF OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Comment already deleted';
  END IF;

  IF NEW.deleted_at IS NULL THEN
    RAISE EXCEPTION 'Comments can only be soft-deleted';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_comment_soft_delete_only"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."find_region_by_location"("search_lat" double precision, "search_lng" double precision) RETURNS TABLE("id" "uuid", "name" character varying, "country_code" character varying, "center_lat" numeric, "center_lon" numeric, "distance_meters" double precision)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT
    r.id,
    r.name,
    r.country_code,
    r.center_lat,
    r.center_lon,
    (
      6371000 * acos(
        LEAST(
          1,
          GREATEST(
            -1,
            cos(radians(search_lat))
            * cos(radians(r.center_lat::double precision))
            * cos(radians(r.center_lon::double precision) - radians(search_lng))
            + sin(radians(search_lat))
            * sin(radians(r.center_lat::double precision))
          )
        )
      )
    ) AS distance_meters
  FROM public.regions r
  WHERE r.center_lat IS NOT NULL
    AND r.center_lon IS NOT NULL
  ORDER BY distance_meters ASC
  LIMIT 1;
$$;


ALTER FUNCTION "public"."find_region_by_location"("search_lat" double precision, "search_lng" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_active_climbers_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(DISTINCT user_id) FROM logs
  WHERE date_climbed >= NOW() - INTERVAL '60 days';
$$;


ALTER FUNCTION "public"."get_active_climbers_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_boulders_with_gps_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(DISTINCT c.crag_id)
  FROM climbs c
  INNER JOIN crags cr ON c.crag_id = cr.id
  WHERE c.deleted_at IS NULL
  AND cr.latitude IS NOT NULL
  AND cr.longitude IS NOT NULL;
$$;


ALTER FUNCTION "public"."get_boulders_with_gps_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_climb_full_context"("p_climb_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO 'public'
    AS $$
WITH climb_target AS (
  SELECT
    c.id,
    c.name,
    c.grade,
    c.route_type,
    c.description
  FROM public.climbs c
  WHERE c.id = p_climb_id
),
primary_image AS (
  SELECT
    i.id,
    i.url,
    i.crag_id,
    i.width,
    i.height,
    i.natural_width,
    i.natural_height,
    i.created_by,
    i.contribution_credit_platform,
    i.contribution_credit_handle,
    i.face_directions
  FROM public.route_lines rl
  JOIN public.images i
    ON i.id = rl.image_id
  WHERE rl.climb_id = p_climb_id
  ORDER BY rl.sequence_order ASC NULLS LAST, rl.created_at ASC
  LIMIT 1
),
primary_routes AS (
  SELECT
    rl.id,
    rl.points,
    rl.color,
    rl.image_width,
    rl.image_height,
    rl.climb_id,
    jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'grade', c.grade,
      'route_type', c.route_type,
      'description', c.description
    ) AS climb
  FROM public.route_lines rl
  JOIN primary_image pi
    ON pi.id = rl.image_id
  JOIN public.climbs c
    ON c.id = rl.climb_id
  ORDER BY rl.sequence_order ASC NULLS LAST, rl.created_at ASC
),
related_faces AS (
  SELECT DISTINCT ON (COALESCE(ci.linked_image_id::TEXT, 'url:' || ci.url))
    ci.id AS crag_image_id,
    ci.url,
    ci.linked_image_id,
    ci.width,
    ci.height,
    ci.face_directions,
    ci.created_at
  FROM public.crag_images ci
  JOIN primary_image pi
    ON pi.crag_id IS NOT NULL
   AND pi.crag_id = ci.crag_id
   AND (
     ci.source_image_id = pi.id
     OR (ci.source_image_id IS NULL AND ci.linked_image_id = pi.id)
   )
  ORDER BY COALESCE(ci.linked_image_id::TEXT, 'url:' || ci.url), ci.created_at ASC
),
all_face_image_ids AS (
  SELECT pi.id AS image_id
  FROM primary_image pi
  UNION
  SELECT rf.linked_image_id
  FROM related_faces rf
  WHERE rf.linked_image_id IS NOT NULL
),
route_counts AS (
  SELECT
    rl.image_id,
    COUNT(*)::INTEGER AS route_count
  FROM public.route_lines rl
  JOIN all_face_image_ids afi
    ON afi.image_id = rl.image_id
  GROUP BY rl.image_id
),
faces_agg AS (
  SELECT COALESCE(
    jsonb_agg(face_json ORDER BY face_index ASC),
    '[]'::JSONB
  ) AS faces
  FROM (
    SELECT
      0 AS face_index,
      jsonb_build_object(
        'id', 'image:' || pi.id,
        'index', 0,
        'image_id', pi.id,
        'is_primary', TRUE,
        'url', pi.url,
        'linked_image_id', pi.id,
        'crag_image_id', NULL,
        'face_directions', pi.face_directions,
        'metadata', jsonb_build_object(
          'width', COALESCE(pi.natural_width, pi.width),
          'height', COALESCE(pi.natural_height, pi.height)
        ),
        'has_routes', COALESCE(rc.route_count, 0) > 0
      ) AS face_json
    FROM primary_image pi
    LEFT JOIN route_counts rc
      ON rc.image_id = pi.id

    UNION ALL

    SELECT
      ROW_NUMBER() OVER (ORDER BY rf.created_at ASC) AS face_index,
      jsonb_build_object(
        'id', 'crag-image:' || rf.crag_image_id,
        'index', ROW_NUMBER() OVER (ORDER BY rf.created_at ASC),
        'image_id', rf.linked_image_id,
        'is_primary', FALSE,
        'url', rf.url,
        'linked_image_id', CASE WHEN rf.linked_image_id = pi.id THEN NULL ELSE rf.linked_image_id END,
        'crag_image_id', rf.crag_image_id,
        'face_directions', rf.face_directions,
        'metadata', jsonb_build_object(
          'width', COALESCE(li.natural_width, li.width, rf.width),
          'height', COALESCE(li.natural_height, li.height, rf.height)
        ),
        'has_routes', COALESCE(rc.route_count, 0) > 0
      ) AS face_json
    FROM related_faces rf
    CROSS JOIN primary_image pi
    LEFT JOIN public.images li
      ON li.id = rf.linked_image_id
    LEFT JOIN route_counts rc
      ON rc.image_id = rf.linked_image_id
  ) faces_union
),
summary AS (
  SELECT
    COALESCE((SELECT jsonb_array_length(fa.faces) FROM faces_agg fa), 0) AS total_faces,
    COALESCE((SELECT SUM(rc.route_count)::INTEGER FROM route_counts rc), 0) AS total_routes
)
SELECT CASE
  WHEN NOT EXISTS (SELECT 1 FROM climb_target) THEN NULL
  ELSE jsonb_build_object(
    'climb', (SELECT to_jsonb(ct) FROM climb_target ct),
    'primary_image', COALESCE((SELECT to_jsonb(pi) FROM primary_image pi), 'null'::JSONB),
    'primary_route_lines', COALESCE((SELECT jsonb_agg(to_jsonb(pr)) FROM primary_routes pr), '[]'::JSONB),
    'faces', COALESCE((SELECT fa.faces FROM faces_agg fa), '[]'::JSONB),
    'summary', jsonb_build_object(
      'total_faces', (SELECT s.total_faces FROM summary s),
      'total_routes', (SELECT s.total_routes FROM summary s)
    )
  )
END;
$$;


ALTER FUNCTION "public"."get_climb_full_context"("p_climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_climbs_with_consensus"("p_climb_ids" "uuid"[]) RETURNS TABLE("climb_id" "uuid", "consensus_grade" character varying, "total_votes" integer, "grade_tied" boolean)
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_id UUID;
  v_total_votes INTEGER;
  v_avg_points NUMERIC;
  v_nearest_grade VARCHAR(10);
BEGIN
  FOR i IN 1..array_length(p_climb_ids, 1) LOOP
    v_id := p_climb_ids[i];

    SELECT INTO v_total_votes COUNT(*) FROM grade_votes WHERE grade_votes.climb_id = v_id;

    IF v_total_votes = 0 THEN
      consensus_grade := NULL;
      total_votes := 0;
      grade_tied := FALSE;
    ELSE
      SELECT INTO v_avg_points AVG(g.points)
      FROM grade_votes gv
      JOIN grades g ON gv.grade = g.grade
      WHERE gv.climb_id = v_id;

      SELECT INTO v_nearest_grade grade
      FROM grades
      ORDER BY ABS(points - v_avg_points)
      LIMIT 1;

      consensus_grade := v_nearest_grade;
      total_votes := v_total_votes;
      grade_tied := FALSE;
    END IF;

    climb_id := v_id;
    RETURN NEXT;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."get_climbs_with_consensus"("p_climb_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_community_photos_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(*) FROM images;
$$;


ALTER FUNCTION "public"."get_community_photos_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_consensus_grade"("climb_id" "uuid") RETURNS character varying
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN (
    SELECT gv.grade
    FROM public.grade_votes gv
    WHERE gv.climb_id = get_consensus_grade.climb_id
    GROUP BY gv.grade
    ORDER BY COUNT(*) DESC
    LIMIT 1
  );
END;
$$;


ALTER FUNCTION "public"."get_consensus_grade"("climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_crag_faces_complete_summary"("p_image_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO 'public'
    AS $$
WITH target AS (
  SELECT
    i.id,
    i.crag_id,
    i.url,
    i.width,
    i.height,
    i.natural_width,
    i.natural_height,
    i.face_directions
  FROM public.images i
  WHERE i.id = p_image_id
),
related_faces_raw AS (
  SELECT
    ci.id AS crag_image_id,
    ci.url,
    ci.linked_image_id,
    ci.width,
    ci.height,
    ci.face_directions,
    ci.created_at
  FROM public.crag_images ci
  JOIN target t
    ON t.crag_id IS NOT NULL
   AND ci.crag_id = t.crag_id
   AND (
     ci.source_image_id = t.id
     OR (ci.source_image_id IS NULL AND ci.linked_image_id = t.id)
   )
),
related_faces AS (
  SELECT DISTINCT ON (COALESCE(rfr.linked_image_id::text, 'url:' || rfr.url))
    rfr.crag_image_id,
    rfr.url,
    rfr.linked_image_id,
    rfr.width,
    rfr.height,
    rfr.face_directions,
    rfr.created_at
  FROM related_faces_raw rfr
  ORDER BY COALESCE(rfr.linked_image_id::text, 'url:' || rfr.url), rfr.created_at ASC
),
all_image_ids AS (
  SELECT t.id AS image_id
  FROM target t
  UNION
  SELECT rf.linked_image_id
  FROM related_faces rf
  WHERE rf.linked_image_id IS NOT NULL
),
routes_by_image AS (
  SELECT
    rl.image_id,
    jsonb_agg(
      jsonb_build_object(
        'id', rl.id,
        'climb_id', rl.climb_id,
        'name', c.name,
        'grade', c.grade,
        'route_type', c.route_type,
        'description', c.description,
        'color', rl.color,
        'points', rl.points,
        'image_width', rl.image_width,
        'image_height', rl.image_height,
        'sequence_order', rl.sequence_order
      )
      ORDER BY rl.sequence_order ASC, rl.created_at ASC
    ) AS routes,
    COUNT(*)::INTEGER AS route_count
  FROM public.route_lines rl
  JOIN public.climbs c
    ON c.id = rl.climb_id
  JOIN all_image_ids ai
    ON ai.image_id = rl.image_id
  GROUP BY rl.image_id
),
primary_face AS (
  SELECT jsonb_build_object(
    'image_id', t.id,
    'index', 0,
    'is_primary', true,
    'url', t.url,
    'linked_image_id', t.id,
    'crag_image_id', NULL,
    'face_directions', t.face_directions,
    'metadata', jsonb_build_object(
      'width', COALESCE(t.natural_width, t.width),
      'height', COALESCE(t.natural_height, t.height)
    ),
    'routes', COALESCE(rbi.routes, '[]'::jsonb),
    'has_routes', COALESCE(rbi.route_count, 0) > 0
  ) AS face_json
  FROM target t
  LEFT JOIN routes_by_image rbi
    ON rbi.image_id = t.id
),
supplementary_faces AS (
  SELECT jsonb_build_object(
    'image_id', rf.linked_image_id,
    'index', ROW_NUMBER() OVER (ORDER BY rf.created_at ASC),
    'is_primary', false,
    'url', rf.url,
    'linked_image_id', CASE WHEN rf.linked_image_id = p_image_id THEN NULL ELSE rf.linked_image_id END,
    'crag_image_id', rf.crag_image_id,
    'face_directions', rf.face_directions,
    'metadata', jsonb_build_object(
      'width', COALESCE(li.natural_width, li.width, rf.width),
      'height', COALESCE(li.natural_height, li.height, rf.height)
    ),
    'routes', COALESCE(rbi.routes, '[]'::jsonb),
    'has_routes', COALESCE(rbi.route_count, 0) > 0
  ) AS face_json
  FROM related_faces rf
  LEFT JOIN public.images li
    ON li.id = rf.linked_image_id
  LEFT JOIN routes_by_image rbi
    ON rbi.image_id = rf.linked_image_id
),
faces_agg AS (
  SELECT COALESCE(jsonb_agg(face_json ORDER BY (face_json->>'index')::INTEGER ASC), '[]'::jsonb) AS faces
  FROM (
    SELECT face_json FROM primary_face
    UNION ALL
    SELECT face_json FROM supplementary_faces
  ) faces
),
summary AS (
  SELECT
    COALESCE((SELECT jsonb_array_length(faces) FROM faces_agg), 0) AS total_faces,
    COALESCE((SELECT SUM(route_count)::INTEGER FROM routes_by_image), 0) AS total_routes
)
SELECT CASE
  WHEN NOT EXISTS (SELECT 1 FROM target) THEN NULL
  ELSE jsonb_build_object(
    'crag_id', (SELECT crag_id FROM target),
    'primary_image_id', (SELECT id FROM target),
    'faces', (SELECT faces FROM faces_agg),
    'summary', jsonb_build_object(
      'total_faces', (SELECT total_faces FROM summary),
      'total_routes', (SELECT total_routes FROM summary)
    )
  )
END;
$$;


ALTER FUNCTION "public"."get_crag_faces_complete_summary"("p_image_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_crag_pins"() RETURNS TABLE("id" "uuid", "name" "text", "latitude" numeric, "longitude" numeric, "image_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    c.name::TEXT,
    AVG(i.latitude)::NUMERIC(10,8) AS latitude,
    AVG(i.longitude)::NUMERIC(11,8) AS longitude,
    COUNT(i.id)::BIGINT AS image_count
  FROM public.crags c
  INNER JOIN public.images i ON i.crag_id = c.id 
    AND i.status = 'approved' 
    AND i.latitude IS NOT NULL
    AND i.longitude IS NOT NULL
  GROUP BY c.id, c.name
  HAVING COUNT(i.id) > 0;
END;
$$;


ALTER FUNCTION "public"."get_crag_pins"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_crag_pins"("include_pending" boolean DEFAULT false) RETURNS TABLE("id" "uuid", "name" "text", "latitude" numeric, "longitude" numeric, "image_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.name::TEXT,
    AVG(i.latitude)::NUMERIC(10,8) AS latitude,
    AVG(i.longitude)::NUMERIC(11,8) AS longitude,
    COUNT(i.id)::BIGINT AS image_count
  FROM public.crags c
  INNER JOIN public.images i ON i.crag_id = c.id
    AND i.status != 'deleted'
    AND (
      i.status = 'approved'
      OR (include_pending AND i.status = 'pending')
    )
    AND i.latitude IS NOT NULL
    AND i.longitude IS NOT NULL
  GROUP BY c.id, c.name
  HAVING COUNT(i.id) > 0;
END;
$$;


ALTER FUNCTION "public"."get_crag_pins"("include_pending" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_grade_vote_distribution"("climb_id" "uuid") RETURNS TABLE("grade" character varying, "vote_count" integer)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT gv.grade, COUNT(*)::INTEGER AS vote_count
  FROM public.grade_votes gv
  WHERE gv.climb_id = get_grade_vote_distribution.climb_id
  GROUP BY gv.grade
  ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_grade_vote_distribution"("climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_image_faces_summary"("p_image_id" "uuid") RETURNS TABLE("total_faces" integer, "total_routes_combined" integer)
    LANGUAGE "sql"
    SET "search_path" TO 'public'
    AS $$
WITH target AS (
  SELECT id, crag_id
  FROM public.images
  WHERE id = p_image_id
),
related_faces AS (
  SELECT ci.id, ci.linked_image_id
  FROM public.crag_images ci
  JOIN target t
    ON ci.crag_id = t.crag_id
   AND (ci.source_image_id = t.id OR ci.linked_image_id = t.id)
),
all_image_ids AS (
  SELECT t.id AS image_id
  FROM target t
  UNION
  SELECT rf.linked_image_id
  FROM related_faces rf
  WHERE rf.linked_image_id IS NOT NULL
),
route_ids AS (
  SELECT DISTINCT rl.id
  FROM public.route_lines rl
  JOIN all_image_ids ai
    ON ai.image_id = rl.image_id
)
SELECT
  COALESCE((SELECT 1 + COUNT(*)::INTEGER FROM related_faces), 1) AS total_faces,
  COALESCE((SELECT COUNT(*)::INTEGER FROM route_ids), 0) AS total_routes_combined;
$$;


ALTER FUNCTION "public"."get_image_faces_summary"("p_image_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_star_rating_summary"("p_climb_id" "uuid") RETURNS TABLE("avg_rating" numeric, "rating_count" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT
    ROUND(AVG(star_rating)::numeric, 2) AS avg_rating,
    COUNT(star_rating)::int AS rating_count
  FROM public.user_climbs
  WHERE climb_id = p_climb_id
    AND star_rating IS NOT NULL;
$$;


ALTER FUNCTION "public"."get_star_rating_summary"("p_climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_total_climbs_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(*) FROM climbs WHERE deleted_at IS NULL;
$$;


ALTER FUNCTION "public"."get_total_climbs_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_total_logs_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(*) FROM user_climbs;
$$;


ALTER FUNCTION "public"."get_total_logs_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_total_sends_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(*) FROM logs
  WHERE status IN ('completed', 'flash', 'onsight');
$$;


ALTER FUNCTION "public"."get_total_sends_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(*) FROM users;
$$;


ALTER FUNCTION "public"."get_user_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_verification_count"("climb_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN (
    SELECT COUNT(*)
    FROM public.climb_verifications cv
    WHERE cv.climb_id = get_verification_count.climb_id
  );
END;
$$;


ALTER FUNCTION "public"."get_verification_count"("climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_verified_routes_count"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT COUNT(*) FROM climbs
  WHERE (verification_count >= 3 OR is_verified = true)
  AND deleted_at IS NULL;
$$;


ALTER FUNCTION "public"."get_verified_routes_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grade_votes_sync_climb_grade_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  target_climb_id UUID;
BEGIN
  target_climb_id := COALESCE(NEW.climb_id, OLD.climb_id);
  PERFORM public.sync_climb_grade_from_votes(target_climb_id);
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."grade_votes_sync_climb_grade_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  -- Skip if no email (Mailpit sometimes creates users without email)
  IF NEW.email IS NULL THEN
    RETURN NEW;
  END IF;
  
  -- Check if profile exists for this email
  IF EXISTS (SELECT 1 FROM public.profiles WHERE email = NEW.email) THEN
    -- Update existing profile with new auth user ID (preserve is_admin)
    UPDATE public.profiles 
    SET id = NEW.id, updated_at = NOW()
    WHERE email = NEW.email;
  ELSE
    -- Create new profile (is_admin defaults to false)
    INSERT INTO public.profiles (id, email, is_admin)
    VALUES (NEW.id, NEW.email, false);
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_user_metadata_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  provider_text text;
BEGIN
  provider_text := NULL;

  -- Prefer auth.users.raw_app_meta_data; tolerate schemas that also expose app_metadata.
  BEGIN
    provider_text := NEW.app_metadata->>'provider';
  EXCEPTION
    WHEN undefined_column THEN
      BEGIN
        provider_text := NEW.raw_app_meta_data->>'provider';
      EXCEPTION
        WHEN undefined_column THEN
          provider_text := NULL;
      END;
  END;

  IF NEW.raw_user_meta_data IS DISTINCT FROM OLD.raw_user_meta_data
     AND COALESCE(provider_text, '') = 'google' THEN
    UPDATE public.profiles
    SET
      first_name = COALESCE(
        NEW.raw_user_meta_data->>'given_name',
        split_part(NEW.raw_user_meta_data->>'full_name', ' ', 1)
      ),
      last_name = COALESCE(
        NEW.raw_user_meta_data->>'family_name',
        split_part(NEW.raw_user_meta_data->>'full_name', ' ', 2)
      ),
      avatar_url = COALESCE(
        NEW.raw_user_meta_data->>'avatar_url',
        NEW.raw_user_meta_data->>'picture'
      ),
      email = COALESCE(NEW.email, email),
      updated_at = NOW()
    WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_user_metadata_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."images_recompute_crag_location_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.recompute_crag_location(NEW.crag_id);
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.crag_id IS DISTINCT FROM OLD.crag_id THEN
      PERFORM public.recompute_crag_location(OLD.crag_id);
      PERFORM public.recompute_crag_location(NEW.crag_id);
      PERFORM public.delete_empty_crag(OLD.crag_id, interval '0 seconds');
      RETURN NEW;
    END IF;

    IF NEW.latitude IS DISTINCT FROM OLD.latitude OR NEW.longitude IS DISTINCT FROM OLD.longitude THEN
      PERFORM public.recompute_crag_location(NEW.crag_id);
      RETURN NEW;
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    PERFORM public.recompute_crag_location(OLD.crag_id);
    PERFORM public.delete_empty_crag(OLD.crag_id, interval '0 seconds');
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."images_recompute_crag_location_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_crag_report_count"("target_crag_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  UPDATE crags SET report_count = report_count + 1 WHERE id = target_crag_id;
END;
$$;


ALTER FUNCTION "public"."increment_crag_report_count"("target_crag_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_gear_click"("product_id_input" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
    BEGIN
      INSERT INTO public.product_clicks (product_id, click_count, updated_at)
      VALUES (product_id_input, 1, NOW())
      ON CONFLICT (product_id)
      DO UPDATE SET
        click_count = public.product_clicks.click_count + 1,
        updated_at = NOW();
    END;
    $$;


ALTER FUNCTION "public"."increment_gear_click"("product_id_input" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."initialize_climb_consensus"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_climb_id UUID;
  v_consensus_grade VARCHAR(10);
  v_total_votes INTEGER;
  v_max_votes INTEGER;
  v_tied_grades INTEGER;
BEGIN
  FOR v_climb_id IN SELECT id FROM climbs LOOP
    SELECT INTO v_max_votes MAX(vote_count)
    FROM (
      SELECT grade, COUNT(*) as vote_count
      FROM grade_votes
      WHERE climb_id = v_climb_id
      GROUP BY grade
    ) sub;

    SELECT INTO v_tied_grades COUNT(*)
    FROM (
      SELECT grade, COUNT(*) as vote_count
      FROM grade_votes
      WHERE climb_id = v_climb_id
      GROUP BY grade
    ) sub
    WHERE vote_count = v_max_votes;

    SELECT INTO v_consensus_grade MIN(grade)
    FROM (
      SELECT grade, COUNT(*) as vote_count
      FROM grade_votes
      WHERE climb_id = v_climb_id
      GROUP BY grade
    ) sub
    WHERE vote_count = v_max_votes;

    SELECT INTO v_total_votes COUNT(*)
    FROM grade_votes
    WHERE climb_id = v_climb_id;

    UPDATE climbs
    SET
      consensus_grade = v_consensus_grade,
      total_votes = COALESCE(v_total_votes, 0),
      grade_tied = v_tied_grades > 1,
      updated_at = NOW()
    WHERE id = v_climb_id;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."initialize_climb_consensus"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."initialize_climb_grade_vote"("p_climb_id" "uuid", "p_user_id" "uuid", "p_grade" character varying) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_count INTEGER;
  v_consensus_grade VARCHAR(10);
  v_tied_grades INTEGER;
BEGIN
  INSERT INTO grade_votes (climb_id, user_id, grade)
  VALUES (p_climb_id, p_user_id, p_grade)
  ON CONFLICT (climb_id, user_id) 
  DO UPDATE SET grade = EXCLUDED.grade, created_at = NOW();

  -- Update the climbs consensus columns directly
  SELECT INTO v_count COUNT(*) FROM grade_votes WHERE climb_id = p_climb_id;
  
  IF v_count = 0 THEN
    UPDATE climbs SET consensus_grade = NULL, total_votes = 0, grade_tied = FALSE WHERE id = p_climb_id;
  ELSE
    SELECT INTO v_tied_grades COUNT(*) FROM (
      SELECT grade, COUNT(*) as cnt FROM grade_votes WHERE climb_id = p_climb_id GROUP BY grade
    ) sub WHERE cnt = (SELECT MAX(cnt) FROM (SELECT COUNT(*) as cnt FROM grade_votes WHERE climb_id = p_climb_id GROUP BY grade) sub2);
    
    SELECT INTO v_consensus_grade MIN(grade) FROM (
      SELECT grade, COUNT(*) as cnt FROM grade_votes WHERE climb_id = p_climb_id GROUP BY grade
    ) sub WHERE cnt = (SELECT MAX(cnt) FROM (SELECT COUNT(*) as cnt FROM grade_votes WHERE climb_id = p_climb_id GROUP BY grade) sub2);
    
    UPDATE climbs SET 
      consensus_grade = v_consensus_grade, 
      total_votes = v_count, 
      grade_tied = v_tied_grades > 1 
    WHERE id = p_climb_id;
  END IF;
END;
$$;


ALTER FUNCTION "public"."initialize_climb_grade_vote"("p_climb_id" "uuid", "p_user_id" "uuid", "p_grade" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_grade_vote"("p_climb_id" "uuid", "vote_grade" character varying) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  INSERT INTO public.grade_votes (climb_id, user_id, grade)
  VALUES (p_climb_id, auth.uid(), vote_grade)
  ON CONFLICT (climb_id, user_id)
  DO UPDATE SET grade = EXCLUDED.grade, created_at = NOW();
END;
$$;


ALTER FUNCTION "public"."insert_grade_vote"("p_climb_id" "uuid", "vote_grade" character varying) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."crag_images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "crag_id" "uuid" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "width" integer,
    "height" integer,
    "linked_image_id" "uuid",
    "source_image_id" "uuid",
    "face_directions" "text"[],
    CONSTRAINT "crag_images_face_directions_check" CHECK ((("face_directions" IS NULL) OR ("face_directions" <@ ARRAY['N'::"text", 'NE'::"text", 'E'::"text", 'SE'::"text", 'S'::"text", 'SW'::"text", 'W'::"text", 'NW'::"text"]))),
    CONSTRAINT "crag_images_url_check" CHECK (("char_length"(TRIM(BOTH FROM "url")) > 0))
);


ALTER TABLE "public"."crag_images" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_pin_images_atomic"("p_crag_id" "uuid", "p_urls" "text"[]) RETURNS SETOF "public"."crag_images"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_crag_id IS NULL THEN
    RAISE EXCEPTION 'crag_id is required';
  END IF;

  IF p_urls IS NULL OR cardinality(p_urls) = 0 THEN
    RAISE EXCEPTION 'At least one image URL is required';
  END IF;

  RETURN QUERY
  INSERT INTO public.crag_images (crag_id, url)
  SELECT
    p_crag_id,
    trim(url_item)
  FROM unnest(p_urls) AS url_item
  WHERE trim(url_item) <> ''
  RETURNING *;
END;
$$;


ALTER FUNCTION "public"."insert_pin_images_atomic"("p_crag_id" "uuid", "p_urls" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_climb_verified"("climb_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM public.climb_verifications cv
    WHERE cv.climb_id = is_climb_verified.climb_id
    GROUP BY cv.climb_id
    HAVING COUNT(*) >= 3
  );
END;
$$;


ALTER FUNCTION "public"."is_climb_verified"("climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_profile_public"("user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
    RETURN (
        SELECT COALESCE(is_public, true)
        FROM profiles
        WHERE id = user_id
    );
END;
$$;


ALTER FUNCTION "public"."is_profile_public"("user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_submission_collaborator"("p_image_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.submission_collaborators sc
    WHERE sc.image_id = p_image_id
      AND sc.user_id = p_user_id
  );
$$;


ALTER FUNCTION "public"."is_submission_collaborator"("p_image_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_climb_route_type"("raw_type" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  normalized TEXT;
BEGIN
  IF raw_type IS NULL THEN
    RETURN NULL;
  END IF;

  normalized := lower(trim(replace(raw_type, '_', '-')));

  IF normalized = 'bouldering' THEN
    RETURN 'boulder';
  ELSIF normalized = 'boulder' THEN
    RETURN 'boulder';
  ELSIF normalized = 'sport' THEN
    RETURN 'sport';
  ELSIF normalized = 'trad' THEN
    RETURN 'trad';
  ELSIF normalized = 'mixed' THEN
    RETURN 'mixed';
  ELSIF normalized = 'deep-water-solo' THEN
    RETURN 'deep_water_solo';
  ELSIF normalized = 'top-rope' THEN
    RETURN 'top_rope';
  END IF;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."normalize_climb_route_type"("raw_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."patch_submission_draft_images_atomic"("p_draft_id" "uuid", "p_images" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
  owner_user_id UUID;
  payload_count INTEGER;
  distinct_id_count INTEGER;
  distinct_order_count INTEGER;
  draft_image_count INTEGER;
  updated_count INTEGER;
  updated_at_value TIMESTAMPTZ;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_draft_id IS NULL THEN
    RAISE EXCEPTION 'Draft ID is required';
  END IF;

  IF p_images IS NULL OR jsonb_typeof(p_images) <> 'array' OR jsonb_array_length(p_images) = 0 THEN
    RAISE EXCEPTION 'images payload must be a non-empty array';
  END IF;

  SELECT user_id INTO owner_user_id
  FROM public.submission_drafts
  WHERE id = p_draft_id
  FOR UPDATE;

  IF owner_user_id IS NULL THEN
    RAISE EXCEPTION 'Draft not found';
  END IF;

  IF owner_user_id <> current_user_id THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  WITH payload AS (
    SELECT
      (item->>'id')::UUID AS id,
      (item->>'display_order')::INTEGER AS display_order,
      COALESCE(item->'route_data', '{}'::JSONB) AS route_data
    FROM jsonb_array_elements(p_images) AS item
  )
  SELECT
    COUNT(*),
    COUNT(DISTINCT id),
    COUNT(DISTINCT display_order)
  INTO payload_count, distinct_id_count, distinct_order_count
  FROM payload;

  IF payload_count <> distinct_id_count THEN
    RAISE EXCEPTION 'Duplicate image IDs in payload';
  END IF;

  IF payload_count <> distinct_order_count THEN
    RAISE EXCEPTION 'Duplicate display_order values in payload';
  END IF;

  SELECT COUNT(*) INTO draft_image_count
  FROM public.submission_draft_images
  WHERE draft_id = p_draft_id;

  IF draft_image_count <> payload_count THEN
    RAISE EXCEPTION 'Payload must include all draft images';
  END IF;

  IF EXISTS (
    WITH payload AS (
      SELECT (item->>'id')::UUID AS id
      FROM jsonb_array_elements(p_images) AS item
    )
    SELECT 1
    FROM payload p
    LEFT JOIN public.submission_draft_images di
      ON di.id = p.id AND di.draft_id = p_draft_id
    WHERE di.id IS NULL
  ) THEN
    RAISE EXCEPTION 'One or more images do not belong to this draft';
  END IF;

  WITH ordered AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY display_order, id) AS rn
    FROM public.submission_draft_images
    WHERE draft_id = p_draft_id
  )
  UPDATE public.submission_draft_images di
  SET display_order = 1000000 + ordered.rn
  FROM ordered
  WHERE di.id = ordered.id;

  WITH payload AS (
    SELECT
      (item->>'id')::UUID AS id,
      (item->>'display_order')::INTEGER AS display_order,
      COALESCE(item->'route_data', '{}'::JSONB) AS route_data
    FROM jsonb_array_elements(p_images) AS item
  )
  UPDATE public.submission_draft_images di
  SET
    display_order = p.display_order,
    route_data = p.route_data,
    updated_at = NOW()
  FROM payload p
  WHERE di.id = p.id
    AND di.draft_id = p_draft_id;

  GET DIAGNOSTICS updated_count = ROW_COUNT;

  UPDATE public.submission_drafts
  SET updated_at = NOW()
  WHERE id = p_draft_id
  RETURNING updated_at INTO updated_at_value;

  RETURN jsonb_build_object(
    'draft_id', p_draft_id,
    'updated_at', updated_at_value,
    'updated_count', updated_count,
    'images', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', id,
          'display_order', display_order,
          'route_data', route_data,
          'updated_at', updated_at
        )
        ORDER BY display_order
      )
      FROM public.submission_draft_images
      WHERE draft_id = p_draft_id
    )
  );
END;
$$;


ALTER FUNCTION "public"."patch_submission_draft_images_atomic"("p_draft_id" "uuid", "p_images" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_climb_location_from_image"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  target_climb_id uuid;
  img_lat numeric(10,8);
  img_lng numeric(11,8);
BEGIN
  IF TG_OP = 'INSERT' THEN
    target_climb_id := NEW.climb_id;
  ELSIF TG_OP = 'UPDATE' THEN
    target_climb_id := NEW.climb_id;
  ELSIF TG_OP = 'DELETE' THEN
    target_climb_id := OLD.climb_id;
  ELSE
    RETURN OLD;
  END IF;

  IF target_climb_id IS NULL THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    ELSE
      RETURN NEW;
    END IF;
  END IF;

  SELECT i.latitude, i.longitude
  INTO img_lat, img_lng
  FROM public.route_lines rl
  JOIN public.images i ON i.id = rl.image_id
  WHERE rl.climb_id = target_climb_id
  ORDER BY rl.created_at ASC
  LIMIT 1;

  UPDATE public.climbs c
  SET latitude = img_lat,
      longitude = img_lng
  WHERE c.id = target_climb_id;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."recompute_climb_location_from_image"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_crag_counts"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  UPDATE public.crags c SET
    image_count = (
      SELECT COUNT(*)::INTEGER 
      FROM public.images i 
      WHERE i.crag_id = c.id 
        AND i.status = 'approved' 
        AND i.latitude IS NOT NULL
    ),
    route_count = (
      SELECT COUNT(*)::INTEGER 
      FROM public.climbs cl 
      WHERE cl.crag_id = c.id 
        AND cl.status = 'approved'
    );
END;
$$;


ALTER FUNCTION "public"."recompute_crag_counts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_crag_location"("target_crag_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  avg_lat numeric;
  avg_lng numeric;
BEGIN
  IF target_crag_id IS NULL THEN
    RETURN;
  END IF;

  -- Average position from both climbs AND approved images
  SELECT
    avg(combined.lat),
    avg(combined.lng)
  INTO avg_lat, avg_lng
  FROM (
    SELECT c.latitude AS lat, c.longitude AS lng
    FROM public.climbs c
    WHERE c.crag_id = target_crag_id
      AND c.latitude IS NOT NULL
      AND c.longitude IS NOT NULL
    UNION ALL
    SELECT i.latitude AS lat, i.longitude AS lng
    FROM public.images i
    WHERE i.crag_id = target_crag_id
      AND i.status = 'approved'
      AND i.latitude IS NOT NULL
      AND i.longitude IS NOT NULL
  ) combined;

  UPDATE public.crags cr
  SET
    latitude = CASE WHEN avg_lat IS NULL THEN NULL ELSE avg_lat::numeric(10,8) END,
    longitude = CASE WHEN avg_lng IS NULL THEN NULL ELSE avg_lng::numeric(11,8) END
  WHERE cr.id = target_crag_id;
END;
$$;


ALTER FUNCTION "public"."recompute_crag_location"("target_crag_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_crag_type_from_climbs"("target_crag_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  winner_type TEXT;
  winner_count INTEGER;
  has_tie BOOLEAN;
BEGIN
  IF target_crag_id IS NULL THEN
    RETURN;
  END IF;

  WITH normalized_counts AS (
    SELECT
      public.normalize_climb_route_type(c.route_type) AS normalized_type,
      COUNT(*)::INTEGER AS route_count
    FROM public.climbs c
    WHERE c.crag_id = target_crag_id
      AND c.deleted_at IS NULL
      AND COALESCE(c.status, 'approved') = 'approved'
    GROUP BY public.normalize_climb_route_type(c.route_type)
    HAVING public.normalize_climb_route_type(c.route_type) IS NOT NULL
  ), ranked AS (
    SELECT
      normalized_type,
      route_count,
      DENSE_RANK() OVER (ORDER BY route_count DESC) AS count_rank
    FROM normalized_counts
  )
  SELECT
    (SELECT normalized_type FROM ranked WHERE count_rank = 1 LIMIT 1),
    (SELECT route_count FROM ranked WHERE count_rank = 1 LIMIT 1),
    (SELECT COUNT(*) > 1 FROM ranked WHERE count_rank = 1)
  INTO winner_type, winner_count, has_tie;

  IF winner_type IS NULL OR winner_count IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.crags
  SET type = CASE
    WHEN has_tie THEN 'mixed'
    ELSE winner_type
  END
  WHERE id = target_crag_id;
END;
$$;


ALTER FUNCTION "public"."refresh_crag_type_from_climbs"("target_crag_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."slugify"("input" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
  SELECT trim(both '-' FROM regexp_replace(lower(coalesce(input, '')), '[^a-z0-9]+', '-', 'g'))
$$;


ALTER FUNCTION "public"."slugify"("input" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."soft_delete_comment"("p_comment_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  UPDATE public.comments
  SET deleted_at = NOW()
  WHERE id = p_comment_id
    AND author_id = current_user_id
    AND deleted_at IS NULL;

  RETURN FOUND;
END;
$$;


ALTER FUNCTION "public"."soft_delete_comment"("p_comment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_climb_grade_from_votes"("p_climb_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  top_grade VARCHAR(10);
  top_vote_count INTEGER;
  top_grade_count INTEGER;
BEGIN
  IF p_climb_id IS NULL THEN
    RETURN;
  END IF;

  SELECT ranked.grade, ranked.vote_count
  INTO top_grade, top_vote_count
  FROM (
    SELECT gv.grade, COUNT(*)::INTEGER AS vote_count
    FROM public.grade_votes gv
    WHERE gv.climb_id = p_climb_id
    GROUP BY gv.grade
    ORDER BY COUNT(*) DESC, gv.grade ASC
    LIMIT 1
  ) AS ranked;

  IF top_grade IS NULL OR top_vote_count IS NULL THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::INTEGER
  INTO top_grade_count
  FROM (
    SELECT COUNT(*)::INTEGER AS vote_count
    FROM public.grade_votes gv
    WHERE gv.climb_id = p_climb_id
    GROUP BY gv.grade
  ) AS per_grade
  WHERE per_grade.vote_count = top_vote_count;

  IF top_grade_count = 1 THEN
    UPDATE public.climbs
    SET grade = top_grade
    WHERE id = p_climb_id
      AND grade IS DISTINCT FROM top_grade;
  END IF;
END;
$$;


ALTER FUNCTION "public"."sync_climb_grade_from_votes"("p_climb_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_crag_to_place"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  resolved_primary TEXT;
BEGIN
  IF pg_trigger_depth() > 1 THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.places WHERE id = OLD.id AND type = 'crag';
    RETURN OLD;
  END IF;

  resolved_primary := CASE
    WHEN NEW.type IN ('boulder', 'sport', 'trad', 'deep_water_solo', 'mixed', 'top_rope') THEN NEW.type
    WHEN NEW.type = 'crag' THEN 'mixed'
    ELSE 'boulder'
  END;

  INSERT INTO public.places (
    id,
    type,
    name,
    latitude,
    longitude,
    region_id,
    description,
    access_notes,
    rock_type,
    region_name,
    country,
    country_code,
    tide_dependency,
    report_count,
    is_flagged,
    slug,
    primary_discipline,
    disciplines,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    'crag',
    NEW.name,
    NEW.latitude,
    NEW.longitude,
    NEW.region_id,
    NEW.description,
    NEW.access_notes,
    NEW.rock_type,
    NEW.region_name,
    NEW.country,
    NEW.country_code,
    NEW.tide_dependency,
    COALESCE(NEW.report_count, 0),
    COALESCE(NEW.is_flagged, false),
    NEW.slug,
    resolved_primary,
    ARRAY[resolved_primary]::TEXT[],
    COALESCE(NEW.created_at, NOW()),
    COALESCE(NEW.updated_at, NOW())
  )
  ON CONFLICT (id) DO UPDATE
  SET
    type = 'crag',
    name = EXCLUDED.name,
    latitude = EXCLUDED.latitude,
    longitude = EXCLUDED.longitude,
    region_id = EXCLUDED.region_id,
    description = EXCLUDED.description,
    access_notes = EXCLUDED.access_notes,
    rock_type = EXCLUDED.rock_type,
    region_name = EXCLUDED.region_name,
    country = EXCLUDED.country,
    country_code = EXCLUDED.country_code,
    tide_dependency = EXCLUDED.tide_dependency,
    report_count = EXCLUDED.report_count,
    is_flagged = EXCLUDED.is_flagged,
    slug = EXCLUDED.slug,
    primary_discipline = EXCLUDED.primary_discipline,
    disciplines = EXCLUDED.disciplines,
    updated_at = NOW();

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_crag_to_place"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_crag_type_from_climbs"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.refresh_crag_type_from_climbs(OLD.crag_id);
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.crag_id IS DISTINCT FROM NEW.crag_id THEN
    PERFORM public.refresh_crag_type_from_climbs(OLD.crag_id);
  END IF;

  PERFORM public.refresh_crag_type_from_climbs(NEW.crag_id);
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_crag_type_from_climbs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_place_to_crag"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  IF pg_trigger_depth() > 1 THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.type = 'crag' THEN
      DELETE FROM public.crags WHERE id = OLD.id;
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.type = 'crag' THEN
    INSERT INTO public.crags (
      id,
      name,
      latitude,
      longitude,
      region_id,
      description,
      access_notes,
      rock_type,
      type,
      created_at,
      updated_at,
      report_count,
      is_flagged,
      boundary,
      region_name,
      country,
      tide_dependency,
      country_code,
      slug
    )
    VALUES (
      NEW.id,
      NEW.name,
      NEW.latitude,
      NEW.longitude,
      NEW.region_id,
      NEW.description,
      NEW.access_notes,
      NEW.rock_type,
      COALESCE(NEW.primary_discipline, 'boulder'),
      COALESCE(NEW.created_at, NOW()),
      COALESCE(NEW.updated_at, NOW()),
      COALESCE(NEW.report_count, 0),
      COALESCE(NEW.is_flagged, false),
      NEW.boundary,
      NEW.region_name,
      NEW.country,
      NEW.tide_dependency,
      NEW.country_code,
      NEW.slug
    )
    ON CONFLICT (id) DO UPDATE
    SET
      name = EXCLUDED.name,
      latitude = EXCLUDED.latitude,
      longitude = EXCLUDED.longitude,
      region_id = EXCLUDED.region_id,
      description = EXCLUDED.description,
      access_notes = EXCLUDED.access_notes,
      rock_type = EXCLUDED.rock_type,
      type = EXCLUDED.type,
      updated_at = NOW(),
      report_count = EXCLUDED.report_count,
      is_flagged = EXCLUDED.is_flagged,
      boundary = EXCLUDED.boundary,
      region_name = EXCLUDED.region_name,
      country = EXCLUDED.country,
      tide_dependency = EXCLUDED.tide_dependency,
      country_code = EXCLUDED.country_code,
      slug = EXCLUDED.slug;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_place_to_crag"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_profile_on_login"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  IF NEW.email IS NOT NULL THEN
    -- Update existing profile's auth user ID without changing is_admin
    UPDATE public.profiles 
    SET id = NEW.id, updated_at = NOW()
    WHERE email = NEW.email;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_profile_on_login"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_submission_draft_images_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_submission_draft_images_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_submission_drafts_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_submission_drafts_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_recompute_crag_counts_climbs"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  target_crag_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    target_crag_id := OLD.crag_id;
  ELSE
    target_crag_id := NEW.crag_id;
  END IF;

  IF target_crag_id IS NOT NULL THEN
    UPDATE public.crags c SET
      route_count = (
        SELECT COUNT(*)::INTEGER 
        FROM public.climbs cl 
        WHERE cl.crag_id = c.id 
          AND cl.status = 'approved'
      )
    WHERE c.id = target_crag_id;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_recompute_crag_counts_climbs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_recompute_crag_counts_images"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  target_crag_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    target_crag_id := OLD.crag_id;
  ELSE
    target_crag_id := NEW.crag_id;
  END IF;

  IF target_crag_id IS NOT NULL THEN
    UPDATE public.crags c SET
      image_count = (
        SELECT COUNT(*)::INTEGER 
        FROM public.images i 
        WHERE i.crag_id = c.id 
          AND i.status = 'approved' 
          AND i.latitude IS NOT NULL
      )
    WHERE c.id = target_crag_id;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_recompute_crag_counts_images"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_climb_consensus"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_climb_id UUID;
  v_consensus_grade VARCHAR(10);
  v_total_votes INTEGER;
  v_max_votes INTEGER;
  v_tied_grades INTEGER;
BEGIN
  v_climb_id := COALESCE(NEW.climb_id, OLD.climb_id);

  IF v_climb_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT INTO v_max_votes MAX(vote_count)
  FROM (
    SELECT grade, COUNT(*) as vote_count
    FROM grade_votes
    WHERE climb_id = v_climb_id
    GROUP BY grade
  ) sub;

  SELECT INTO v_tied_grades COUNT(*)
  FROM (
    SELECT grade, COUNT(*) as vote_count
    FROM grade_votes
    WHERE climb_id = v_climb_id
    GROUP BY grade
  ) sub
  WHERE vote_count = v_max_votes;

  SELECT INTO v_consensus_grade MIN(grade)
  FROM (
    SELECT grade, COUNT(*) as vote_count
    FROM grade_votes
    WHERE climb_id = v_climb_id
    GROUP BY grade
  ) sub
  WHERE vote_count = v_max_votes;

  SELECT INTO v_total_votes COUNT(*)
  FROM grade_votes
  WHERE climb_id = v_climb_id;

  UPDATE climbs
  SET
    consensus_grade = v_consensus_grade,
    total_votes = COALESCE(v_total_votes, 0),
    grade_tied = v_tied_grades > 1,
    updated_at = NOW()
  WHERE id = v_climb_id;

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_climb_consensus"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_climb_consensus_safe"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_climb_id UUID;
  v_total_votes INTEGER;
  v_consensus_grade VARCHAR(10);
  v_tied_grades INTEGER;
BEGIN
  v_climb_id := COALESCE(NEW.climb_id, OLD.climb_id);
  
  IF v_climb_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT INTO v_total_votes COUNT(*) FROM grade_votes WHERE climb_id = v_climb_id;
  
  IF v_total_votes = 0 THEN
    UPDATE climbs SET consensus_grade = NULL, total_votes = 0, grade_tied = FALSE WHERE id = v_climb_id;
  ELSE
    SELECT INTO v_tied_grades COUNT(*) FROM (
      SELECT grade, COUNT(*) as cnt FROM grade_votes WHERE climb_id = v_climb_id GROUP BY grade
    ) sub WHERE cnt = (SELECT MAX(cnt) FROM (SELECT COUNT(*) as cnt FROM grade_votes WHERE climb_id = v_climb_id GROUP BY grade) sub2);
    
    SELECT INTO v_consensus_grade MIN(grade) FROM (
      SELECT grade, COUNT(*) as cnt FROM grade_votes WHERE climb_id = v_climb_id GROUP BY grade
    ) sub WHERE cnt = (SELECT MAX(cnt) FROM (SELECT COUNT(*) as cnt FROM grade_votes WHERE climb_id = v_climb_id GROUP BY grade) sub2);
    
    UPDATE climbs SET 
      consensus_grade = v_consensus_grade, 
      total_votes = v_total_votes, 
      grade_tied = v_tied_grades > 1 
    WHERE id = v_climb_id;
  END IF;
  
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_climb_consensus_safe"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_own_profile_submission_credit"("p_platform" "text", "p_handle" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $_$
DECLARE
  current_user_id UUID := auth.uid();
  normalized_platform TEXT;
  normalized_handle TEXT;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  normalized_handle := NULLIF(btrim(COALESCE(p_handle, '')), '');

  IF normalized_handle IS NULL THEN
    normalized_platform := NULL;
  ELSE
    normalized_handle := regexp_replace(normalized_handle, '^@+', '');

    IF char_length(normalized_handle) > 50 THEN
      RAISE EXCEPTION 'Handle must be 50 characters or less';
    END IF;

    IF normalized_handle !~ '^[A-Za-z0-9._-]+$' THEN
      RAISE EXCEPTION 'Handle can only include letters, numbers, periods, underscores, and hyphens';
    END IF;

    normalized_platform := lower(NULLIF(btrim(COALESCE(p_platform, '')), ''));

    IF normalized_platform IS NULL THEN
      RAISE EXCEPTION 'Platform is required when a handle is provided';
    END IF;

    IF normalized_platform NOT IN ('instagram', 'tiktok', 'youtube', 'x', 'other') THEN
      RAISE EXCEPTION 'Invalid platform';
    END IF;
  END IF;

  UPDATE public.profiles
  SET
    contribution_credit_platform = normalized_platform,
    contribution_credit_handle = normalized_handle,
    updated_at = NOW()
  WHERE id = current_user_id;

  IF NOT FOUND THEN
    INSERT INTO public.profiles (id, contribution_credit_platform, contribution_credit_handle)
    VALUES (current_user_id, normalized_platform, normalized_handle);
  END IF;

  RETURN jsonb_build_object(
    'platform', normalized_platform,
    'handle', normalized_handle
  );
END;
$_$;


ALTER FUNCTION "public"."update_own_profile_submission_credit"("p_platform" "text", "p_handle" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_own_submission_credit"("p_image_id" "uuid", "p_platform" "text", "p_handle" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $_$
DECLARE
  current_user_id UUID := auth.uid();
  normalized_platform TEXT;
  normalized_handle TEXT;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'Image ID is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.images i
    WHERE i.id = p_image_id
      AND i.created_by = current_user_id
  ) THEN
    RAISE EXCEPTION 'You do not have permission to edit this submission';
  END IF;

  normalized_handle := NULLIF(btrim(COALESCE(p_handle, '')), '');

  IF normalized_handle IS NULL THEN
    normalized_platform := NULL;
  ELSE
    normalized_handle := regexp_replace(normalized_handle, '^@+', '');

    IF char_length(normalized_handle) > 50 THEN
      RAISE EXCEPTION 'Handle must be 50 characters or less';
    END IF;

    IF normalized_handle !~ '^[A-Za-z0-9._-]+$' THEN
      RAISE EXCEPTION 'Handle can only include letters, numbers, periods, underscores, and hyphens';
    END IF;

    normalized_platform := lower(NULLIF(btrim(COALESCE(p_platform, '')), ''));

    IF normalized_platform IS NULL THEN
      RAISE EXCEPTION 'Platform is required when a handle is provided';
    END IF;

    IF normalized_platform NOT IN ('instagram', 'tiktok', 'youtube', 'x', 'other') THEN
      RAISE EXCEPTION 'Invalid platform';
    END IF;
  END IF;

  UPDATE public.images
  SET
    contribution_credit_platform = normalized_platform,
    contribution_credit_handle = normalized_handle
  WHERE id = p_image_id;

  RETURN jsonb_build_object(
    'platform', normalized_platform,
    'handle', normalized_handle
  );
END;
$_$;


ALTER FUNCTION "public"."update_own_submission_credit"("p_image_id" "uuid", "p_platform" "text", "p_handle" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_own_submitted_routes"("p_image_id" "uuid", "p_routes" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
  route_item JSONB;
  route_id UUID;
  climb_id UUID;
  route_name TEXT;
  route_description TEXT;
  route_points JSONB;
  updated_count INTEGER := 0;
  has_access BOOLEAN := false;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'Image ID is required';
  END IF;

  IF p_routes IS NULL OR jsonb_typeof(p_routes) <> 'array' OR jsonb_array_length(p_routes) = 0 THEN
    RAISE EXCEPTION 'At least one route is required';
  END IF;

  SELECT true
  INTO has_access
  FROM public.images i
  WHERE i.id = p_image_id
    AND (
      i.created_by = current_user_id
      OR EXISTS (
        SELECT 1
        FROM public.submission_collaborators sc
        WHERE sc.image_id = i.id
          AND sc.user_id = current_user_id
      )
    )
  LIMIT 1;

  IF COALESCE(has_access, false) = false THEN
    RAISE EXCEPTION 'You do not have permission to edit routes for this image';
  END IF;

  FOR route_item IN
    SELECT value FROM jsonb_array_elements(p_routes)
  LOOP
    BEGIN
      route_id := (route_item->>'id')::UUID;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Invalid route id provided';
    END;

    route_name := btrim(COALESCE(route_item->>'name', ''));
    route_description := NULLIF(btrim(COALESCE(route_item->>'description', '')), '');
    route_points := route_item->'points';

    IF route_name = '' THEN
      RAISE EXCEPTION 'Route name is required';
    END IF;

    IF char_length(route_name) > 200 THEN
      RAISE EXCEPTION 'Route name must be 200 characters or less';
    END IF;

    IF route_description IS NOT NULL AND char_length(route_description) > 500 THEN
      RAISE EXCEPTION 'Route description must be 500 characters or less';
    END IF;

    IF route_points IS NULL OR jsonb_typeof(route_points) <> 'array' OR jsonb_array_length(route_points) < 2 THEN
      RAISE EXCEPTION 'Route points must contain at least 2 points';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(route_points) AS pt
      WHERE jsonb_typeof(pt->'x') <> 'number'
        OR jsonb_typeof(pt->'y') <> 'number'
        OR (pt->>'x')::double precision < 0
        OR (pt->>'x')::double precision > 1
        OR (pt->>'y')::double precision < 0
        OR (pt->>'y')::double precision > 1
    ) THEN
      RAISE EXCEPTION 'Route points must be normalized values between 0 and 1';
    END IF;

    SELECT rl.climb_id
    INTO climb_id
    FROM public.route_lines rl
    WHERE rl.id = route_id
      AND rl.image_id = p_image_id;

    IF climb_id IS NULL THEN
      RAISE EXCEPTION 'Route not found or not editable';
    END IF;

    UPDATE public.climbs
    SET
      name = route_name,
      description = route_description,
      updated_at = NOW()
    WHERE id = climb_id;

    UPDATE public.route_lines
    SET points = route_points
    WHERE id = route_id;

    updated_count := updated_count + 1;
  END LOOP;

  UPDATE public.images
  SET last_edited_by = current_user_id
  WHERE id = p_image_id;

  RETURN updated_count;
END;
$$;


ALTER FUNCTION "public"."update_own_submitted_routes"("p_image_id" "uuid", "p_routes" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_submission_image_metadata"("p_image_id" "uuid", "p_latitude" double precision, "p_longitude" double precision, "p_face_directions" "text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID := auth.uid();
  normalized_face_directions TEXT[];
  has_access BOOLEAN := false;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'Image ID is required';
  END IF;

  IF p_latitude IS NOT NULL AND (p_latitude < -90 OR p_latitude > 90) THEN
    RAISE EXCEPTION 'Latitude must be between -90 and 90';
  END IF;

  IF p_longitude IS NOT NULL AND (p_longitude < -180 OR p_longitude > 180) THEN
    RAISE EXCEPTION 'Longitude must be between -180 and 180';
  END IF;

  SELECT true
  INTO has_access
  FROM public.images i
  WHERE i.id = p_image_id
    AND (
      i.created_by = current_user_id
      OR EXISTS (
        SELECT 1
        FROM public.submission_collaborators sc
        WHERE sc.image_id = i.id
          AND sc.user_id = current_user_id
      )
    )
  LIMIT 1;

  IF COALESCE(has_access, false) = false THEN
    RAISE EXCEPTION 'You do not have permission to edit this submission';
  END IF;

  IF p_face_directions IS NULL OR array_length(p_face_directions, 1) IS NULL THEN
    normalized_face_directions := NULL;
  ELSE
    IF EXISTS (
      SELECT 1
      FROM unnest(p_face_directions) AS direction
      WHERE direction IS NULL
        OR btrim(direction) = ''
        OR upper(btrim(direction)) NOT IN ('N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW')
    ) THEN
      RAISE EXCEPTION 'Invalid face direction provided';
    END IF;

    SELECT COALESCE(array_agg(direction ORDER BY min_idx), ARRAY[]::TEXT[])
    INTO normalized_face_directions
    FROM (
      SELECT upper(btrim(direction)) AS direction, MIN(ord) AS min_idx
      FROM unnest(p_face_directions) WITH ORDINALITY AS t(direction, ord)
      GROUP BY upper(btrim(direction))
    ) normalized;

    IF array_length(normalized_face_directions, 1) IS NULL THEN
      normalized_face_directions := NULL;
    END IF;
  END IF;

  UPDATE public.images
  SET
    latitude = p_latitude,
    longitude = p_longitude,
    face_directions = normalized_face_directions,
    face_direction = CASE
      WHEN normalized_face_directions IS NULL OR array_length(normalized_face_directions, 1) IS NULL THEN NULL
      ELSE normalized_face_directions[1]
    END,
    last_edited_by = current_user_id
  WHERE id = p_image_id;

  RETURN jsonb_build_object(
    'latitude', p_latitude,
    'longitude', p_longitude,
    'face_directions', COALESCE(to_jsonb(normalized_face_directions), '[]'::JSONB)
  );
END;
$$;


ALTER FUNCTION "public"."update_submission_image_metadata"("p_image_id" "uuid", "p_latitude" double precision, "p_longitude" double precision, "p_face_directions" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_comment_target"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  IF NEW.target_type = 'crag' THEN
    IF NOT EXISTS (SELECT 1 FROM public.crags c WHERE c.id = NEW.target_id) THEN
      RAISE EXCEPTION 'Target crag does not exist';
    END IF;
  ELSIF NEW.target_type = 'image' THEN
    IF NOT EXISTS (SELECT 1 FROM public.images i WHERE i.id = NEW.target_id) THEN
      RAISE EXCEPTION 'Target image does not exist';
    END IF;
  ELSIF NEW.target_type = 'climb' THEN
    IF NOT EXISTS (SELECT 1 FROM public.climbs cl WHERE cl.id = NEW.target_id) THEN
      RAISE EXCEPTION 'Target climb does not exist';
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid target type';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_comment_target"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "action" character varying(20) NOT NULL,
    "target_id" "uuid" NOT NULL,
    "target_type" character varying(20),
    "details" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admin_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."climb_corrections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "correction_type" character varying(20) NOT NULL,
    "original_value" "jsonb",
    "suggested_value" "jsonb" NOT NULL,
    "reason" "text",
    "status" character varying(20) DEFAULT 'pending'::character varying,
    "approval_count" integer DEFAULT 0,
    "rejection_count" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "resolved_at" timestamp with time zone,
    CONSTRAINT "climb_corrections_correction_type_check" CHECK ((("correction_type")::"text" = ANY ((ARRAY['location'::character varying, 'name'::character varying, 'line'::character varying, 'grade'::character varying])::"text"[]))),
    CONSTRAINT "climb_corrections_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying])::"text"[])))
);


ALTER TABLE "public"."climb_corrections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."climb_flags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "climb_id" "uuid",
    "crag_id" "uuid",
    "flagger_id" "uuid",
    "flag_type" character varying(50) NOT NULL,
    "comment" "text" NOT NULL,
    "status" character varying(20) DEFAULT 'pending'::character varying,
    "action_taken" character varying(20),
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "image_id" "uuid",
    CONSTRAINT "climb_flags_action_taken_check" CHECK ((("action_taken")::"text" = ANY ((ARRAY['keep'::character varying, 'edit'::character varying, 'remove'::character varying])::"text"[]))),
    CONSTRAINT "climb_flags_flag_type_check" CHECK ((("flag_type")::"text" = ANY ((ARRAY['location'::character varying, 'route_line'::character varying, 'route_name'::character varying, 'image_quality'::character varying, 'wrong_crag'::character varying, 'boundary'::character varying, 'access'::character varying, 'description'::character varying, 'rock_type'::character varying, 'name'::character varying, 'other'::character varying])::"text"[]))),
    CONSTRAINT "climb_flags_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'resolved'::character varying])::"text"[])))
);


ALTER TABLE "public"."climb_flags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."climb_verifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."climb_verifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."climb_video_betas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "url" "text" NOT NULL,
    "platform" "text" DEFAULT 'other'::"text" NOT NULL,
    "title" "text",
    "notes" "text",
    "uploader_gender" "text",
    "uploader_height_cm" integer,
    "uploader_reach_cm" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "climb_video_betas_platform_check" CHECK (("platform" = ANY (ARRAY['youtube'::"text", 'instagram'::"text", 'tiktok'::"text", 'vimeo'::"text", 'other'::"text"]))),
    CONSTRAINT "climb_video_betas_uploader_gender_check" CHECK (("uploader_gender" = ANY (ARRAY['male'::"text", 'female'::"text", 'other'::"text", 'prefer_not_to_say'::"text"]))),
    CONSTRAINT "climb_video_betas_uploader_height_cm_check" CHECK ((("uploader_height_cm" IS NULL) OR (("uploader_height_cm" >= 100) AND ("uploader_height_cm" <= 250)))),
    CONSTRAINT "climb_video_betas_uploader_reach_cm_check" CHECK ((("uploader_reach_cm" IS NULL) OR (("uploader_reach_cm" >= 100) AND ("uploader_reach_cm" <= 260))))
);


ALTER TABLE "public"."climb_video_betas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."climbs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying(200),
    "grade" character varying(10) NOT NULL,
    "status" character varying(20) DEFAULT 'pending'::character varying,
    "route_type" character varying(20),
    "description" "text",
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "verification_count" integer DEFAULT 0,
    "is_verified" boolean DEFAULT false,
    "crag_id" "uuid",
    "slug" "text",
    "consensus_grade" character varying(10),
    "total_votes" integer DEFAULT 0,
    "grade_tied" boolean DEFAULT false,
    "place_id" "uuid",
    "latitude" numeric(10,8),
    "longitude" numeric(11,8),
    "grade_index" integer,
    "original_grade_string" character varying(24)
);


ALTER TABLE "public"."climbs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "author_id" "uuid",
    "body" "text" NOT NULL,
    "category" "text" DEFAULT 'other'::"text" NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comments_body_check" CHECK ((("char_length"("body") >= 1) AND ("char_length"("body") <= 2000))),
    CONSTRAINT "comments_category_check" CHECK (("category" = ANY (ARRAY['access'::"text", 'approach'::"text", 'parking'::"text", 'closure'::"text", 'general'::"text", 'beta'::"text", 'fa_history'::"text", 'safety'::"text", 'gear_protection'::"text", 'conditions'::"text", 'approach_access'::"text", 'descent'::"text", 'rock_quality'::"text", 'highlights'::"text", 'variations'::"text", 'topo_error'::"text", 'line_request'::"text", 'photo_outdated'::"text", 'other_topo'::"text", 'broken_hold'::"text", 'grade'::"text", 'history'::"text"]))),
    CONSTRAINT "comments_target_type_check" CHECK (("target_type" = ANY (ARRAY['crag'::"text", 'image'::"text", 'climb'::"text"])))
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_place_follows" (
    "place_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "notification_level" "text" DEFAULT 'all'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "community_place_follows_notification_level_check" CHECK (("notification_level" = ANY (ARRAY['all'::"text", 'daily'::"text", 'off'::"text"])))
);


ALTER TABLE "public"."community_place_follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_post_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "community_post_comments_body_check" CHECK ((("char_length"("body") >= 1) AND ("char_length"("body") <= 2000)))
);


ALTER TABLE "public"."community_post_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_post_rsvps" (
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'going'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "community_post_rsvps_status_check" CHECK (("status" = ANY (ARRAY['going'::"text", 'interested'::"text"])))
);


ALTER TABLE "public"."community_post_rsvps" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "title" "text",
    "body" "text" NOT NULL,
    "discipline" "text",
    "grade_min" "text",
    "grade_max" "text",
    "start_at" timestamp with time zone,
    "end_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "community_posts_body_check" CHECK ((("char_length"("body") >= 1) AND ("char_length"("body") <= 2000))),
    CONSTRAINT "community_posts_discipline_check" CHECK (("discipline" = ANY (ARRAY['boulder'::"text", 'sport'::"text", 'trad'::"text", 'deep_water_solo'::"text", 'mixed'::"text", 'top_rope'::"text"]))),
    CONSTRAINT "community_posts_end_after_start" CHECK ((("end_at" IS NULL) OR ("start_at" IS NULL) OR ("end_at" >= "start_at"))),
    CONSTRAINT "community_posts_grade_max_length" CHECK ((("grade_max" IS NULL) OR ("char_length"("grade_max") <= 10))),
    CONSTRAINT "community_posts_grade_min_length" CHECK ((("grade_min" IS NULL) OR ("char_length"("grade_min") <= 10))),
    CONSTRAINT "community_posts_session_start_required" CHECK ((("type" <> 'session'::"text") OR ("start_at" IS NOT NULL))),
    CONSTRAINT "community_posts_title_length" CHECK ((("title" IS NULL) OR (("char_length"("title") >= 1) AND ("char_length"("title") <= 120)))),
    CONSTRAINT "community_posts_type_check" CHECK (("type" = ANY (ARRAY['session'::"text", 'update'::"text", 'conditions'::"text", 'question'::"text"])))
);


ALTER TABLE "public"."community_posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."correction_votes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "correction_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "vote_type" character varying(10) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "correction_votes_vote_type_check" CHECK ((("vote_type")::"text" = ANY ((ARRAY['approve'::character varying, 'reject'::character varying])::"text"[])))
);


ALTER TABLE "public"."correction_votes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crag_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "crag_id" "uuid" NOT NULL,
    "reporter_id" "uuid",
    "reason" "text" NOT NULL,
    "details" "text",
    "status" character varying(20) DEFAULT 'pending'::character varying,
    "moderator_id" "uuid",
    "moderator_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "resolved_at" timestamp with time zone,
    CONSTRAINT "crag_reports_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'investigating'::character varying, 'resolved'::character varying, 'dismissed'::character varying])::"text"[])))
);


ALTER TABLE "public"."crag_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying(200) NOT NULL,
    "latitude" numeric(10,8),
    "longitude" numeric(11,8),
    "region_id" "uuid",
    "description" "text",
    "access_notes" "text",
    "rock_type" character varying(50),
    "type" character varying(20) DEFAULT 'sport'::character varying,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "report_count" integer DEFAULT 0,
    "is_flagged" boolean DEFAULT false,
    "region_name" character varying(100),
    "country" character varying(100),
    "tide_dependency" character varying(20),
    "country_code" character varying(2),
    "slug" "text",
    "image_count" integer DEFAULT 0,
    "route_count" integer DEFAULT 0
);


ALTER TABLE "public"."crags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deleted_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delete_route_uploads" boolean DEFAULT false NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."deleted_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deletion_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "scheduled_at" timestamp with time zone NOT NULL,
    "cancelled_at" timestamp with time zone,
    "delete_route_uploads" boolean DEFAULT false NOT NULL,
    "primary_reason" "text",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."deletion_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."grade_mappings" (
    "grade_index" integer NOT NULL,
    "v_scale" character varying(10),
    "font_scale" character varying(10),
    "yds_equivalent" character varying(10),
    "french_equivalent" character varying(10),
    "difficulty_group" character varying(20),
    "british_equivalent" character varying(10)
);


ALTER TABLE "public"."grade_mappings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."grade_votes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "grade" character varying(10) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."grade_votes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."grades" (
    "grade" "text" NOT NULL,
    "points" integer NOT NULL
);


ALTER TABLE "public"."grades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gym_floor_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "gym_place_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "image_url" "text" NOT NULL,
    "image_width" integer NOT NULL,
    "image_height" integer NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gym_floor_plans_image_height_check" CHECK (("image_height" > 0)),
    CONSTRAINT "gym_floor_plans_image_width_check" CHECK (("image_width" > 0)),
    CONSTRAINT "gym_floor_plans_name_check" CHECK ((("char_length"("name") >= 1) AND ("char_length"("name") <= 160)))
);


ALTER TABLE "public"."gym_floor_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gym_memberships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "gym_place_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gym_memberships_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'manager'::"text", 'head_setter'::"text", 'setter'::"text"]))),
    CONSTRAINT "gym_memberships_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'invited'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."gym_memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gym_owner_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "gym_name" "text" NOT NULL,
    "address" "text" NOT NULL,
    "facilities" "text"[] NOT NULL,
    "contact_phone" "text" NOT NULL,
    "contact_email" "text" NOT NULL,
    "role" "text" NOT NULL,
    "additional_comments" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "city" "text" NOT NULL,
    "country" "text" NOT NULL,
    "postcode_or_zip" "text" NOT NULL,
    CONSTRAINT "gym_owner_applications_address_check" CHECK ((("char_length"("address") >= 1) AND ("char_length"("address") <= 300))),
    CONSTRAINT "gym_owner_applications_city_length" CHECK ((("char_length"("city") >= 1) AND ("char_length"("city") <= 120))),
    CONSTRAINT "gym_owner_applications_contact_email_check" CHECK ((("char_length"("contact_email") >= 3) AND ("char_length"("contact_email") <= 160))),
    CONSTRAINT "gym_owner_applications_contact_phone_check" CHECK ((("char_length"("contact_phone") >= 1) AND ("char_length"("contact_phone") <= 40))),
    CONSTRAINT "gym_owner_applications_country_length" CHECK ((("char_length"("country") >= 1) AND ("char_length"("country") <= 120))),
    CONSTRAINT "gym_owner_applications_facilities_not_empty" CHECK (("cardinality"("facilities") >= 1)),
    CONSTRAINT "gym_owner_applications_facilities_valid" CHECK (("facilities" <@ ARRAY['sport'::"text", 'boulder'::"text"])),
    CONSTRAINT "gym_owner_applications_gym_name_check" CHECK ((("char_length"("gym_name") >= 1) AND ("char_length"("gym_name") <= 200))),
    CONSTRAINT "gym_owner_applications_postcode_or_zip_length" CHECK ((("char_length"("postcode_or_zip") >= 1) AND ("char_length"("postcode_or_zip") <= 32))),
    CONSTRAINT "gym_owner_applications_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'manager'::"text", 'head_setter'::"text"]))),
    CONSTRAINT "gym_owner_applications_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'reviewing'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."gym_owner_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gym_route_markers" (
    "route_id" "uuid" NOT NULL,
    "x_norm" numeric(8,6) NOT NULL,
    "y_norm" numeric(8,6) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gym_route_markers_x_norm_check" CHECK ((("x_norm" >= (0)::numeric) AND ("x_norm" <= (1)::numeric))),
    CONSTRAINT "gym_route_markers_y_norm_check" CHECK ((("y_norm" >= (0)::numeric) AND ("y_norm" <= (1)::numeric)))
);


ALTER TABLE "public"."gym_route_markers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gym_routes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "gym_place_id" "uuid" NOT NULL,
    "floor_plan_id" "uuid" NOT NULL,
    "name" "text",
    "grade" "text" NOT NULL,
    "discipline" "text" NOT NULL,
    "color" "text",
    "setter_name" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gym_routes_discipline_check" CHECK (("discipline" = ANY (ARRAY['boulder'::"text", 'sport'::"text", 'top_rope'::"text", 'mixed'::"text"]))),
    CONSTRAINT "gym_routes_grade_check" CHECK ((("char_length"("grade") >= 1) AND ("char_length"("grade") <= 24))),
    CONSTRAINT "gym_routes_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'retired'::"text"])))
);


ALTER TABLE "public"."gym_routes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "url" "text" NOT NULL,
    "latitude" numeric(10,8),
    "longitude" numeric(11,8),
    "capture_date" timestamp with time zone,
    "crag_id" "uuid",
    "width" integer,
    "height" integer,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "verification_count" integer DEFAULT 0,
    "is_verified" boolean DEFAULT false,
    "natural_width" integer,
    "natural_height" integer,
    "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    "has_humans" boolean,
    "moderated_at" timestamp with time zone,
    "moderation_labels" "jsonb",
    "moderation_status" "text" DEFAULT 'pending'::"text",
    "face_direction" character varying(2),
    "storage_bucket" "text",
    "storage_path" "text",
    "place_id" "uuid",
    "face_directions" "text"[],
    "contribution_credit_platform" "text",
    "contribution_credit_handle" "text",
    "last_edited_by" "uuid",
    CONSTRAINT "images_face_direction_check" CHECK ((("face_direction" IS NULL) OR (("face_direction")::"text" = ANY ((ARRAY['N'::character varying, 'NE'::character varying, 'E'::character varying, 'SE'::character varying, 'S'::character varying, 'SW'::character varying, 'W'::character varying, 'NW'::character varying])::"text"[])))),
    CONSTRAINT "images_face_directions_check" CHECK ((("face_directions" IS NULL) OR ("face_directions" <@ ARRAY['N'::"text", 'NE'::"text", 'E'::"text", 'SE'::"text", 'S'::"text", 'SW'::"text", 'W'::"text", 'NW'::"text"]))),
    CONSTRAINT "images_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying, 'deleted'::character varying])::"text"[])))
);


ALTER TABLE "public"."images" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" character varying(50) NOT NULL,
    "title" "text" NOT NULL,
    "message" "text",
    "link" "text",
    "is_read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."places" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "type" "text" NOT NULL,
    "name" character varying(200) NOT NULL,
    "latitude" numeric(10,8),
    "longitude" numeric(11,8),
    "region_id" "uuid",
    "description" "text",
    "access_notes" "text",
    "rock_type" character varying(50),
    "region_name" character varying(100),
    "country" character varying(100),
    "country_code" character varying(2),
    "tide_dependency" character varying(20),
    "report_count" integer DEFAULT 0 NOT NULL,
    "is_flagged" boolean DEFAULT false NOT NULL,
    "slug" "text",
    "primary_discipline" "text",
    "disciplines" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "places_disciplines_valid" CHECK (("disciplines" <@ ARRAY['boulder'::"text", 'sport'::"text", 'trad'::"text", 'deep_water_solo'::"text", 'mixed'::"text", 'top_rope'::"text"])),
    CONSTRAINT "places_gym_disciplines_guard" CHECK ((("type" <> 'gym'::"text") OR (NOT ("disciplines" && ARRAY['trad'::"text", 'deep_water_solo'::"text"])))),
    CONSTRAINT "places_primary_discipline_in_disciplines" CHECK ((("primary_discipline" IS NULL) OR ("primary_discipline" = ANY ("disciplines")))),
    CONSTRAINT "places_primary_discipline_valid" CHECK ((("primary_discipline" IS NULL) OR ("primary_discipline" = ANY (ARRAY['boulder'::"text", 'sport'::"text", 'trad'::"text", 'deep_water_solo'::"text", 'mixed'::"text", 'top_rope'::"text"])))),
    CONSTRAINT "places_type_check" CHECK (("type" = ANY (ARRAY['crag'::"text", 'gym'::"text"])))
);


ALTER TABLE "public"."places" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_clicks" (
    "product_id" "text" NOT NULL,
    "click_count" bigint DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."product_clicks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text",
    "display_name" "text",
    "avatar_url" "text",
    "bio" "text",
    "gender" "text",
    "country" character varying(100),
    "country_code" character varying(2),
    "preferred_grade_system" character varying(10) DEFAULT 'french'::character varying,
    "preferred_style" character varying(20) DEFAULT 'sport'::character varying,
    "total_climbs" integer DEFAULT 0,
    "total_points" integer DEFAULT 0,
    "highest_grade" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "name" "text",
    "default_location" "text",
    "default_location_name" "text",
    "default_location_lat" numeric(10,8),
    "default_location_lng" numeric(11,8),
    "default_location_zoom" integer,
    "grade_system" character varying(20) DEFAULT 'font'::character varying,
    "units" character varying(10) DEFAULT 'metric'::character varying,
    "is_public" boolean DEFAULT true,
    "theme_preference" character varying(20) DEFAULT 'system'::character varying,
    "first_name" "text",
    "last_name" "text",
    "email" "text",
    "name_updated_at" timestamp with time zone,
    "is_admin" boolean DEFAULT false,
    "tos_accepted_at" timestamp with time zone,
    "welcome_email_sent_at" timestamp with time zone,
    "height_cm" integer,
    "reach_cm" integer,
    "contribution_credit_platform" "text",
    "contribution_credit_handle" "text",
    "boulder_system" character varying(20) DEFAULT 'v_scale'::character varying,
    "route_system" character varying(20) DEFAULT 'yds_equivalent'::character varying,
    "trad_system" character varying(20) DEFAULT 'yds_equivalent'::character varying,
    CONSTRAINT "profiles_gender_check" CHECK (("gender" = ANY (ARRAY['male'::"text", 'female'::"text", 'other'::"text", 'prefer_not_to_say'::"text"]))),
    CONSTRAINT "profiles_height_cm_check" CHECK ((("height_cm" IS NULL) OR (("height_cm" >= 100) AND ("height_cm" <= 250)))),
    CONSTRAINT "profiles_reach_cm_check" CHECK ((("reach_cm" IS NULL) OR (("reach_cm" >= 100) AND ("reach_cm" <= 260))))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."regions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying(100) NOT NULL,
    "country_code" character varying(2),
    "center_lat" numeric(10,8),
    "center_lon" numeric(11,8),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "description" "text"
);


ALTER TABLE "public"."regions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."route_grades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "grade" character varying(10) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."route_grades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."route_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "image_id" "uuid" NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "points" "jsonb" NOT NULL,
    "color" character varying(20) DEFAULT 'red'::character varying,
    "sequence_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "image_width" integer,
    "image_height" integer
);


ALTER TABLE "public"."route_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."submission_collaborator_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "image_id" "uuid" NOT NULL,
    "token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_by" "uuid",
    "max_uses" integer,
    "used_count" integer DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "submission_collaborator_invites_max_uses_check" CHECK ((("max_uses" IS NULL) OR ("max_uses" > 0))),
    CONSTRAINT "submission_collaborator_invites_used_count_check" CHECK (("used_count" >= 0)),
    CONSTRAINT "submission_collaborator_invites_uses_window_check" CHECK ((("max_uses" IS NULL) OR ("used_count" <= "max_uses")))
);


ALTER TABLE "public"."submission_collaborator_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."submission_collaborators" (
    "image_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'editor'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "submission_collaborators_role_check" CHECK (("role" = 'editor'::"text"))
);


ALTER TABLE "public"."submission_collaborators" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."submission_draft_images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "display_order" integer NOT NULL,
    "storage_bucket" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "width" integer,
    "height" integer,
    "route_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "linked_image_id" "uuid",
    "linked_crag_image_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "submission_draft_images_display_order_check" CHECK (("display_order" >= 0)),
    CONSTRAINT "submission_draft_images_storage_bucket_check" CHECK (("char_length"(TRIM(BOTH FROM "storage_bucket")) > 0)),
    CONSTRAINT "submission_draft_images_storage_path_check" CHECK (("char_length"(TRIM(BOTH FROM "storage_path")) > 0))
);


ALTER TABLE "public"."submission_draft_images" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."submission_drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "crag_id" "uuid",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "submission_drafts_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'submitted'::"text"])))
);


ALTER TABLE "public"."submission_drafts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_climbs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "climb_id" "uuid" NOT NULL,
    "style" character varying(20) NOT NULL,
    "notes" "text",
    "date_climbed" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "grade_opinion" character varying(10),
    "grade_vote_baseline" character varying(10),
    "star_rating" smallint,
    CONSTRAINT "user_climbs_grade_opinion_check" CHECK ((("grade_opinion" IS NULL) OR (("grade_opinion")::"text" = ANY ((ARRAY['soft'::character varying, 'agree'::character varying, 'hard'::character varying])::"text"[])))),
    CONSTRAINT "user_climbs_star_rating_check" CHECK ((("star_rating" IS NULL) OR (("star_rating" >= 1) AND ("star_rating" <= 5))))
);


ALTER TABLE "public"."user_climbs" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admin_actions"
    ADD CONSTRAINT "admin_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."climb_corrections"
    ADD CONSTRAINT "climb_corrections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."climb_flags"
    ADD CONSTRAINT "climb_flags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."climb_verifications"
    ADD CONSTRAINT "climb_verifications_climb_id_user_id_key" UNIQUE ("climb_id", "user_id");



ALTER TABLE ONLY "public"."climb_verifications"
    ADD CONSTRAINT "climb_verifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."climb_video_betas"
    ADD CONSTRAINT "climb_video_betas_climb_id_user_id_url_key" UNIQUE ("climb_id", "user_id", "url");



ALTER TABLE ONLY "public"."climb_video_betas"
    ADD CONSTRAINT "climb_video_betas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."climbs"
    ADD CONSTRAINT "climbs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_place_follows"
    ADD CONSTRAINT "community_place_follows_pkey" PRIMARY KEY ("place_id", "user_id");



ALTER TABLE ONLY "public"."community_post_comments"
    ADD CONSTRAINT "community_post_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_post_rsvps"
    ADD CONSTRAINT "community_post_rsvps_pkey" PRIMARY KEY ("post_id", "user_id");



ALTER TABLE ONLY "public"."community_posts"
    ADD CONSTRAINT "community_posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."correction_votes"
    ADD CONSTRAINT "correction_votes_correction_id_user_id_key" UNIQUE ("correction_id", "user_id");



ALTER TABLE ONLY "public"."correction_votes"
    ADD CONSTRAINT "correction_votes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."crag_images"
    ADD CONSTRAINT "crag_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."crag_reports"
    ADD CONSTRAINT "crag_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."crags"
    ADD CONSTRAINT "crags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."deleted_accounts"
    ADD CONSTRAINT "deleted_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."deletion_requests"
    ADD CONSTRAINT "deletion_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grade_mappings"
    ADD CONSTRAINT "grade_mappings_pkey" PRIMARY KEY ("grade_index");



ALTER TABLE ONLY "public"."grade_votes"
    ADD CONSTRAINT "grade_votes_climb_id_user_id_key" UNIQUE ("climb_id", "user_id");



ALTER TABLE ONLY "public"."grade_votes"
    ADD CONSTRAINT "grade_votes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grades"
    ADD CONSTRAINT "grades_pkey" PRIMARY KEY ("grade");



ALTER TABLE ONLY "public"."gym_floor_plans"
    ADD CONSTRAINT "gym_floor_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gym_memberships"
    ADD CONSTRAINT "gym_memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gym_owner_applications"
    ADD CONSTRAINT "gym_owner_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gym_route_markers"
    ADD CONSTRAINT "gym_route_markers_pkey" PRIMARY KEY ("route_id");



ALTER TABLE ONLY "public"."gym_routes"
    ADD CONSTRAINT "gym_routes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_climbs"
    ADD CONSTRAINT "idx_user_climbs_unique" UNIQUE ("user_id", "climb_id");



ALTER TABLE ONLY "public"."images"
    ADD CONSTRAINT "images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_clicks"
    ADD CONSTRAINT "product_clicks_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."regions"
    ADD CONSTRAINT "regions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."route_grades"
    ADD CONSTRAINT "route_grades_climb_id_user_id_key" UNIQUE ("climb_id", "user_id");



ALTER TABLE ONLY "public"."route_grades"
    ADD CONSTRAINT "route_grades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."route_lines"
    ADD CONSTRAINT "route_lines_image_id_climb_id_key" UNIQUE ("image_id", "climb_id");



ALTER TABLE ONLY "public"."route_lines"
    ADD CONSTRAINT "route_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."submission_collaborator_invites"
    ADD CONSTRAINT "submission_collaborator_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."submission_collaborator_invites"
    ADD CONSTRAINT "submission_collaborator_invites_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."submission_collaborators"
    ADD CONSTRAINT "submission_collaborators_pkey" PRIMARY KEY ("image_id", "user_id");



ALTER TABLE ONLY "public"."submission_draft_images"
    ADD CONSTRAINT "submission_draft_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."submission_drafts"
    ADD CONSTRAINT "submission_drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_climbs"
    ADD CONSTRAINT "user_climbs_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_admin_actions_target" ON "public"."admin_actions" USING "btree" ("target_id", "target_type");



CREATE INDEX "idx_climb_corrections_climb" ON "public"."climb_corrections" USING "btree" ("climb_id");



CREATE INDEX "idx_climb_corrections_status" ON "public"."climb_corrections" USING "btree" ("status");



CREATE INDEX "idx_climb_corrections_user" ON "public"."climb_corrections" USING "btree" ("user_id");



CREATE INDEX "idx_climb_flags_climb" ON "public"."climb_flags" USING "btree" ("climb_id");



CREATE INDEX "idx_climb_flags_flagged_by" ON "public"."climb_flags" USING "btree" ("flagger_id");



CREATE INDEX "idx_climb_flags_image" ON "public"."climb_flags" USING "btree" ("image_id");



CREATE INDEX "idx_climb_flags_resolved_by" ON "public"."climb_flags" USING "btree" ("resolved_by");



CREATE INDEX "idx_climb_flags_status" ON "public"."climb_flags" USING "btree" ("status");



CREATE INDEX "idx_climb_verifications_climb" ON "public"."climb_verifications" USING "btree" ("climb_id");



CREATE INDEX "idx_climb_verifications_user" ON "public"."climb_verifications" USING "btree" ("user_id");



CREATE INDEX "idx_climb_video_betas_climb_created_at" ON "public"."climb_video_betas" USING "btree" ("climb_id", "created_at" DESC);



CREATE INDEX "idx_climb_video_betas_climb_platform" ON "public"."climb_video_betas" USING "btree" ("climb_id", "platform");



CREATE INDEX "idx_climb_video_betas_user_created_at" ON "public"."climb_video_betas" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_climbs_consensus_grade" ON "public"."climbs" USING "btree" ("consensus_grade") WHERE ("consensus_grade" IS NOT NULL);



CREATE INDEX "idx_climbs_created_at" ON "public"."climbs" USING "btree" ("created_at");



CREATE INDEX "idx_climbs_grade" ON "public"."climbs" USING "btree" ("grade");



CREATE INDEX "idx_climbs_grade_index" ON "public"."climbs" USING "btree" ("grade_index");



CREATE INDEX "idx_climbs_name" ON "public"."climbs" USING "btree" ("name");



CREATE INDEX "idx_climbs_place" ON "public"."climbs" USING "btree" ("place_id");



CREATE INDEX "idx_climbs_slug" ON "public"."climbs" USING "btree" ("slug");



CREATE INDEX "idx_climbs_status" ON "public"."climbs" USING "btree" ("status");



CREATE INDEX "idx_climbs_user" ON "public"."climbs" USING "btree" ("user_id");



CREATE INDEX "idx_comments_author_created" ON "public"."comments" USING "btree" ("author_id", "created_at" DESC);



CREATE INDEX "idx_comments_target_created" ON "public"."comments" USING "btree" ("target_type", "target_id", "created_at" DESC);



CREATE INDEX "idx_comments_visible_target_created" ON "public"."comments" USING "btree" ("target_type", "target_id", "created_at" DESC) WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_community_place_follows_user_updated" ON "public"."community_place_follows" USING "btree" ("user_id", "updated_at" DESC);



CREATE INDEX "idx_community_post_comments_author_created" ON "public"."community_post_comments" USING "btree" ("author_id", "created_at" DESC);



CREATE INDEX "idx_community_post_comments_post_created" ON "public"."community_post_comments" USING "btree" ("post_id", "created_at");



CREATE INDEX "idx_community_post_rsvps_user_created" ON "public"."community_post_rsvps" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_community_posts_author_created" ON "public"."community_posts" USING "btree" ("author_id", "created_at" DESC);



CREATE INDEX "idx_community_posts_place_created" ON "public"."community_posts" USING "btree" ("place_id", "created_at" DESC);



CREATE INDEX "idx_community_posts_place_type_created" ON "public"."community_posts" USING "btree" ("place_id", "type", "created_at" DESC);



CREATE INDEX "idx_community_posts_session_place_start" ON "public"."community_posts" USING "btree" ("place_id", "start_at") WHERE ("type" = 'session'::"text");



CREATE INDEX "idx_correction_votes_correction" ON "public"."correction_votes" USING "btree" ("correction_id");



CREATE INDEX "idx_correction_votes_user" ON "public"."correction_votes" USING "btree" ("user_id");



CREATE INDEX "idx_crag_images_crag_id" ON "public"."crag_images" USING "btree" ("crag_id");



CREATE INDEX "idx_crag_images_created_at" ON "public"."crag_images" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_crag_images_linked_image_id" ON "public"."crag_images" USING "btree" ("linked_image_id");



CREATE INDEX "idx_crag_images_source_image_id" ON "public"."crag_images" USING "btree" ("source_image_id");



CREATE INDEX "idx_crag_reports_crag" ON "public"."crag_reports" USING "btree" ("crag_id");



CREATE INDEX "idx_crag_reports_reporter" ON "public"."crag_reports" USING "btree" ("reporter_id");



CREATE INDEX "idx_crag_reports_status" ON "public"."crag_reports" USING "btree" ("status");



CREATE INDEX "idx_crags_country_code" ON "public"."crags" USING "btree" ("country_code");



CREATE INDEX "idx_crags_image_count" ON "public"."crags" USING "btree" ("image_count");



CREATE INDEX "idx_crags_is_flagged" ON "public"."crags" USING "btree" ("is_flagged");



CREATE INDEX "idx_crags_location" ON "public"."crags" USING "btree" ("latitude", "longitude");



CREATE INDEX "idx_crags_name" ON "public"."crags" USING "btree" ("name");



CREATE INDEX "idx_crags_nearby_cover" ON "public"."crags" USING "btree" ("latitude", "longitude") INCLUDE ("id", "name", "rock_type", "type");



CREATE INDEX "idx_crags_region" ON "public"."crags" USING "btree" ("region_id");



CREATE INDEX "idx_crags_report_count" ON "public"."crags" USING "btree" ("report_count");



CREATE INDEX "idx_crags_route_count" ON "public"."crags" USING "btree" ("route_count");



CREATE INDEX "idx_crags_slug" ON "public"."crags" USING "btree" ("slug");



CREATE INDEX "idx_crags_type" ON "public"."crags" USING "btree" ("type");



CREATE INDEX "idx_deleted_accounts_deleted_at" ON "public"."deleted_accounts" USING "btree" ("deleted_at" DESC);



CREATE INDEX "idx_deleted_accounts_email" ON "public"."deleted_accounts" USING "btree" ("email");



CREATE INDEX "idx_deleted_accounts_user_id" ON "public"."deleted_accounts" USING "btree" ("user_id");



CREATE INDEX "idx_deletion_requests_scheduled" ON "public"."deletion_requests" USING "btree" ("scheduled_at") WHERE (("cancelled_at" IS NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "idx_grade_votes_climb" ON "public"."grade_votes" USING "btree" ("climb_id");



CREATE INDEX "idx_grade_votes_user" ON "public"."grade_votes" USING "btree" ("user_id");



CREATE INDEX "idx_grades_points" ON "public"."grades" USING "btree" ("points");



CREATE INDEX "idx_gym_floor_plans_gym" ON "public"."gym_floor_plans" USING "btree" ("gym_place_id");



CREATE INDEX "idx_gym_memberships_gym_status" ON "public"."gym_memberships" USING "btree" ("gym_place_id", "status");



CREATE INDEX "idx_gym_memberships_user_status" ON "public"."gym_memberships" USING "btree" ("user_id", "status");



CREATE INDEX "idx_gym_owner_applications_created" ON "public"."gym_owner_applications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_gym_owner_applications_status_created" ON "public"."gym_owner_applications" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_gym_routes_floor_plan" ON "public"."gym_routes" USING "btree" ("floor_plan_id");



CREATE INDEX "idx_gym_routes_gym" ON "public"."gym_routes" USING "btree" ("gym_place_id");



CREATE INDEX "idx_gym_routes_status" ON "public"."gym_routes" USING "btree" ("status");



CREATE INDEX "idx_images_crag" ON "public"."images" USING "btree" ("crag_id");



CREATE INDEX "idx_images_created_at" ON "public"."images" USING "btree" ("created_at");



CREATE INDEX "idx_images_created_by" ON "public"."images" USING "btree" ("created_by");



CREATE INDEX "idx_images_location" ON "public"."images" USING "btree" ("latitude", "longitude");



CREATE INDEX "idx_images_moderation_status" ON "public"."images" USING "btree" ("moderation_status");



CREATE INDEX "idx_images_place" ON "public"."images" USING "btree" ("place_id");



CREATE INDEX "idx_images_status" ON "public"."images" USING "btree" ("status") WHERE (("status")::"text" = 'pending'::"text");



CREATE INDEX "idx_images_storage_location" ON "public"."images" USING "btree" ("storage_bucket", "storage_path");



CREATE INDEX "idx_notifications_created" ON "public"."notifications" USING "btree" ("created_at");



CREATE INDEX "idx_notifications_unread" ON "public"."notifications" USING "btree" ("user_id", "is_read") WHERE ("is_read" = false);



CREATE INDEX "idx_notifications_user" ON "public"."notifications" USING "btree" ("user_id");



CREATE INDEX "idx_places_country_code" ON "public"."places" USING "btree" ("country_code");



CREATE INDEX "idx_places_location" ON "public"."places" USING "btree" ("latitude", "longitude");



CREATE INDEX "idx_places_name" ON "public"."places" USING "btree" ("name");



CREATE INDEX "idx_places_region" ON "public"."places" USING "btree" ("region_id");



CREATE INDEX "idx_places_slug" ON "public"."places" USING "btree" ("slug");



CREATE INDEX "idx_places_type" ON "public"."places" USING "btree" ("type");



CREATE INDEX "idx_product_clicks_count" ON "public"."product_clicks" USING "btree" ("click_count" DESC);



CREATE INDEX "idx_profiles_email" ON "public"."profiles" USING "btree" ("email");



CREATE INDEX "idx_profiles_first_name" ON "public"."profiles" USING "btree" ("first_name");



CREATE INDEX "idx_profiles_is_public" ON "public"."profiles" USING "btree" ("is_public");



CREATE INDEX "idx_profiles_last_name" ON "public"."profiles" USING "btree" ("last_name");



CREATE INDEX "idx_profiles_name_updated" ON "public"."profiles" USING "btree" ("name_updated_at");



CREATE INDEX "idx_profiles_username" ON "public"."profiles" USING "btree" ("username");



CREATE INDEX "idx_profiles_welcome_email_sent_at" ON "public"."profiles" USING "btree" ("welcome_email_sent_at") WHERE ("welcome_email_sent_at" IS NULL);



CREATE INDEX "idx_regions_center" ON "public"."regions" USING "btree" ("center_lat", "center_lon");



CREATE INDEX "idx_route_grades_climb" ON "public"."route_grades" USING "btree" ("climb_id");



CREATE INDEX "idx_route_grades_user" ON "public"."route_grades" USING "btree" ("user_id");



CREATE INDEX "idx_route_lines_climb" ON "public"."route_lines" USING "btree" ("climb_id");



CREATE INDEX "idx_route_lines_image" ON "public"."route_lines" USING "btree" ("image_id");



CREATE INDEX "idx_submission_collaborator_invites_image_id" ON "public"."submission_collaborator_invites" USING "btree" ("image_id");



CREATE INDEX "idx_submission_collaborators_user_id" ON "public"."submission_collaborators" USING "btree" ("user_id");



CREATE INDEX "idx_submission_draft_images_draft_id" ON "public"."submission_draft_images" USING "btree" ("draft_id");



CREATE INDEX "idx_submission_drafts_crag_id" ON "public"."submission_drafts" USING "btree" ("crag_id");



CREATE INDEX "idx_submission_drafts_user_status_updated" ON "public"."submission_drafts" USING "btree" ("user_id", "status", "updated_at" DESC);



CREATE INDEX "idx_user_climbs_climb" ON "public"."user_climbs" USING "btree" ("climb_id");



CREATE INDEX "idx_user_climbs_date" ON "public"."user_climbs" USING "btree" ("date_climbed");



CREATE INDEX "idx_user_climbs_grade_opinion" ON "public"."user_climbs" USING "btree" ("climb_id", "grade_opinion") WHERE ("grade_opinion" IS NOT NULL);



CREATE INDEX "idx_user_climbs_user" ON "public"."user_climbs" USING "btree" ("user_id");



CREATE INDEX "idx_user_climbs_user_climb" ON "public"."user_climbs" USING "btree" ("user_id", "climb_id");



CREATE INDEX "idx_user_climbs_user_created" ON "public"."user_climbs" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_user_climbs_user_style" ON "public"."user_climbs" USING "btree" ("user_id", "style");



CREATE UNIQUE INDEX "profiles_id_key" ON "public"."profiles" USING "btree" ("id");



CREATE UNIQUE INDEX "uq_climbs_crag_id_slug" ON "public"."climbs" USING "btree" ("crag_id", "slug") WHERE (("crag_id" IS NOT NULL) AND ("slug" IS NOT NULL));



CREATE UNIQUE INDEX "uq_crags_country_code_slug" ON "public"."crags" USING "btree" ("country_code", "slug") WHERE (("country_code" IS NOT NULL) AND ("slug" IS NOT NULL));



CREATE UNIQUE INDEX "uq_gym_floor_plans_one_active_per_gym" ON "public"."gym_floor_plans" USING "btree" ("gym_place_id") WHERE ("is_active" = true);



CREATE UNIQUE INDEX "uq_gym_memberships_user_gym" ON "public"."gym_memberships" USING "btree" ("user_id", "gym_place_id");



CREATE UNIQUE INDEX "uq_places_country_code_slug" ON "public"."places" USING "btree" ("country_code", "slug") WHERE (("country_code" IS NOT NULL) AND ("slug" IS NOT NULL));



CREATE UNIQUE INDEX "uq_submission_draft_images_draft_order" ON "public"."submission_draft_images" USING "btree" ("draft_id", "display_order");



CREATE OR REPLACE TRIGGER "climbs_recompute_crag_location_delete" AFTER DELETE ON "public"."climbs" FOR EACH ROW EXECUTE FUNCTION "public"."climbs_recompute_crag_location_trigger"();



CREATE OR REPLACE TRIGGER "climbs_recompute_crag_location_insert" AFTER INSERT ON "public"."climbs" FOR EACH ROW EXECUTE FUNCTION "public"."climbs_recompute_crag_location_trigger"();



CREATE OR REPLACE TRIGGER "climbs_recompute_crag_location_update" AFTER UPDATE OF "crag_id", "latitude", "longitude" ON "public"."climbs" FOR EACH ROW EXECUTE FUNCTION "public"."climbs_recompute_crag_location_trigger"();



CREATE OR REPLACE TRIGGER "climbs_sync_crag_type_after_write" AFTER INSERT OR DELETE OR UPDATE OF "route_type", "crag_id", "status", "deleted_at" ON "public"."climbs" FOR EACH ROW EXECUTE FUNCTION "public"."sync_crag_type_from_climbs"();



CREATE OR REPLACE TRIGGER "comments_soft_delete_only_trigger" BEFORE UPDATE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_comment_soft_delete_only"();



CREATE OR REPLACE TRIGGER "comments_validate_target_trigger" BEFORE INSERT OR UPDATE OF "target_type", "target_id" ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."validate_comment_target"();



CREATE OR REPLACE TRIGGER "crags_sync_to_places_after_write" AFTER INSERT OR DELETE OR UPDATE ON "public"."crags" FOR EACH ROW EXECUTE FUNCTION "public"."sync_crag_to_place"();



CREATE OR REPLACE TRIGGER "images_trigger_on_crag_location" AFTER INSERT OR DELETE OR UPDATE ON "public"."images" FOR EACH ROW EXECUTE FUNCTION "public"."images_recompute_crag_location_trigger"();



CREATE OR REPLACE TRIGGER "places_sync_to_crags_after_write" AFTER INSERT OR DELETE OR UPDATE ON "public"."places" FOR EACH ROW EXECUTE FUNCTION "public"."sync_place_to_crag"();



CREATE OR REPLACE TRIGGER "route_lines_set_climb_gps" AFTER INSERT OR UPDATE OF "image_id" ON "public"."route_lines" FOR EACH ROW EXECUTE FUNCTION "public"."recompute_climb_location_from_image"();



CREATE OR REPLACE TRIGGER "trg_grade_votes_sync_climb_grade" AFTER INSERT OR DELETE OR UPDATE OF "grade" ON "public"."grade_votes" FOR EACH ROW EXECUTE FUNCTION "public"."grade_votes_sync_climb_grade_trigger"();



CREATE OR REPLACE TRIGGER "trg_submission_draft_images_updated_at" BEFORE UPDATE ON "public"."submission_draft_images" FOR EACH ROW EXECUTE FUNCTION "public"."touch_submission_draft_images_updated_at"();



CREATE OR REPLACE TRIGGER "trg_submission_drafts_updated_at" BEFORE UPDATE ON "public"."submission_drafts" FOR EACH ROW EXECUTE FUNCTION "public"."touch_submission_drafts_updated_at"();



CREATE OR REPLACE TRIGGER "trg_update_climb_consensus_on_vote" AFTER INSERT OR DELETE OR UPDATE ON "public"."grade_votes" FOR EACH ROW EXECUTE FUNCTION "public"."update_climb_consensus_safe"();



CREATE OR REPLACE TRIGGER "trigger_crag_counts_climbs" AFTER INSERT OR DELETE OR UPDATE OF "status" ON "public"."climbs" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_recompute_crag_counts_climbs"();



CREATE OR REPLACE TRIGGER "trigger_crag_counts_images" AFTER INSERT OR DELETE OR UPDATE OF "status" ON "public"."images" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_recompute_crag_counts_images"();



ALTER TABLE ONLY "public"."climb_corrections"
    ADD CONSTRAINT "climb_corrections_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_corrections"
    ADD CONSTRAINT "climb_corrections_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_flags"
    ADD CONSTRAINT "climb_flags_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_flags"
    ADD CONSTRAINT "climb_flags_crag_id_fkey" FOREIGN KEY ("crag_id") REFERENCES "public"."crags"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."climb_flags"
    ADD CONSTRAINT "climb_flags_flagger_id_fkey" FOREIGN KEY ("flagger_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."climb_flags"
    ADD CONSTRAINT "climb_flags_image_id_fkey" FOREIGN KEY ("image_id") REFERENCES "public"."images"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_flags"
    ADD CONSTRAINT "climb_flags_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."climb_verifications"
    ADD CONSTRAINT "climb_verifications_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_verifications"
    ADD CONSTRAINT "climb_verifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_video_betas"
    ADD CONSTRAINT "climb_video_betas_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climb_video_betas"
    ADD CONSTRAINT "climb_video_betas_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climbs"
    ADD CONSTRAINT "climbs_crag_id_fkey" FOREIGN KEY ("crag_id") REFERENCES "public"."crags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."climbs"
    ADD CONSTRAINT "climbs_grade_index_fkey" FOREIGN KEY ("grade_index") REFERENCES "public"."grade_mappings"("grade_index");



ALTER TABLE ONLY "public"."climbs"
    ADD CONSTRAINT "climbs_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."community_place_follows"
    ADD CONSTRAINT "community_place_follows_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_place_follows"
    ADD CONSTRAINT "community_place_follows_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_post_comments"
    ADD CONSTRAINT "community_post_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_post_comments"
    ADD CONSTRAINT "community_post_comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."community_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_post_rsvps"
    ADD CONSTRAINT "community_post_rsvps_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."community_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_post_rsvps"
    ADD CONSTRAINT "community_post_rsvps_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_posts"
    ADD CONSTRAINT "community_posts_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_posts"
    ADD CONSTRAINT "community_posts_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."correction_votes"
    ADD CONSTRAINT "correction_votes_correction_id_fkey" FOREIGN KEY ("correction_id") REFERENCES "public"."climb_corrections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."correction_votes"
    ADD CONSTRAINT "correction_votes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crag_images"
    ADD CONSTRAINT "crag_images_crag_id_fkey" FOREIGN KEY ("crag_id") REFERENCES "public"."crags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crag_images"
    ADD CONSTRAINT "crag_images_linked_image_id_fkey" FOREIGN KEY ("linked_image_id") REFERENCES "public"."images"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."crag_images"
    ADD CONSTRAINT "crag_images_source_image_id_fkey" FOREIGN KEY ("source_image_id") REFERENCES "public"."images"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."crag_reports"
    ADD CONSTRAINT "crag_reports_crag_id_fkey" FOREIGN KEY ("crag_id") REFERENCES "public"."crags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."crag_reports"
    ADD CONSTRAINT "crag_reports_moderator_id_fkey" FOREIGN KEY ("moderator_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."crag_reports"
    ADD CONSTRAINT "crag_reports_reporter_id_fkey" FOREIGN KEY ("reporter_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."crags"
    ADD CONSTRAINT "crags_region_id_fkey" FOREIGN KEY ("region_id") REFERENCES "public"."regions"("id");



ALTER TABLE ONLY "public"."deletion_requests"
    ADD CONSTRAINT "deletion_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grade_votes"
    ADD CONSTRAINT "grade_votes_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grade_votes"
    ADD CONSTRAINT "grade_votes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gym_floor_plans"
    ADD CONSTRAINT "gym_floor_plans_gym_place_id_fkey" FOREIGN KEY ("gym_place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gym_memberships"
    ADD CONSTRAINT "gym_memberships_gym_place_id_fkey" FOREIGN KEY ("gym_place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gym_memberships"
    ADD CONSTRAINT "gym_memberships_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gym_route_markers"
    ADD CONSTRAINT "gym_route_markers_route_id_fkey" FOREIGN KEY ("route_id") REFERENCES "public"."gym_routes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gym_routes"
    ADD CONSTRAINT "gym_routes_floor_plan_id_fkey" FOREIGN KEY ("floor_plan_id") REFERENCES "public"."gym_floor_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gym_routes"
    ADD CONSTRAINT "gym_routes_gym_place_id_fkey" FOREIGN KEY ("gym_place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."images"
    ADD CONSTRAINT "images_crag_id_fkey" FOREIGN KEY ("crag_id") REFERENCES "public"."crags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."images"
    ADD CONSTRAINT "images_last_edited_by_fkey" FOREIGN KEY ("last_edited_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."images"
    ADD CONSTRAINT "images_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_region_id_fkey" FOREIGN KEY ("region_id") REFERENCES "public"."regions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."route_grades"
    ADD CONSTRAINT "route_grades_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."route_grades"
    ADD CONSTRAINT "route_grades_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."route_lines"
    ADD CONSTRAINT "route_lines_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."route_lines"
    ADD CONSTRAINT "route_lines_image_id_fkey" FOREIGN KEY ("image_id") REFERENCES "public"."images"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."submission_collaborator_invites"
    ADD CONSTRAINT "submission_collaborator_invites_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."submission_collaborator_invites"
    ADD CONSTRAINT "submission_collaborator_invites_image_id_fkey" FOREIGN KEY ("image_id") REFERENCES "public"."images"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."submission_collaborators"
    ADD CONSTRAINT "submission_collaborators_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."submission_collaborators"
    ADD CONSTRAINT "submission_collaborators_image_id_fkey" FOREIGN KEY ("image_id") REFERENCES "public"."images"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."submission_collaborators"
    ADD CONSTRAINT "submission_collaborators_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."submission_draft_images"
    ADD CONSTRAINT "submission_draft_images_draft_id_fkey" FOREIGN KEY ("draft_id") REFERENCES "public"."submission_drafts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."submission_draft_images"
    ADD CONSTRAINT "submission_draft_images_linked_crag_image_id_fkey" FOREIGN KEY ("linked_crag_image_id") REFERENCES "public"."crag_images"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."submission_draft_images"
    ADD CONSTRAINT "submission_draft_images_linked_image_id_fkey" FOREIGN KEY ("linked_image_id") REFERENCES "public"."images"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."submission_drafts"
    ADD CONSTRAINT "submission_drafts_crag_id_fkey" FOREIGN KEY ("crag_id") REFERENCES "public"."crags"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."submission_drafts"
    ADD CONSTRAINT "submission_drafts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_climbs"
    ADD CONSTRAINT "user_climbs_climb_id_fkey" FOREIGN KEY ("climb_id") REFERENCES "public"."climbs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_climbs"
    ADD CONSTRAINT "user_climbs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



CREATE POLICY "Admin manage climb_flags" ON "public"."climb_flags" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admin read all notifications" ON "public"."notifications" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admin read gym owner applications" ON "public"."gym_owner_applications" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admin update gym owner applications" ON "public"."gym_owner_applications" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admin update profiles" ON "public"."profiles" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "profiles_1"
  WHERE (("profiles_1"."id" = "auth"."uid"()) AND ("profiles_1"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles" "profiles_1"
  WHERE (("profiles_1"."id" = "auth"."uid"()) AND ("profiles_1"."is_admin" = true)))));



CREATE POLICY "Admin write gym_floor_plans" ON "public"."gym_floor_plans" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admin write gym_route_markers" ON "public"."gym_route_markers" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admin write gym_routes" ON "public"."gym_routes" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admins can delete climbs" ON "public"."climbs" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admins can delete crags" ON "public"."crags" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admins can delete images" ON "public"."images" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Admins can manage admin actions" ON "public"."admin_actions" USING ((("auth"."jwt"() ->> 'role'::"text") = 'admin'::"text"));



CREATE POLICY "Admins manage gym memberships" ON "public"."gym_memberships" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true)))));



CREATE POLICY "Authenticated create climb_flags" ON "public"."climb_flags" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "flagger_id")));



CREATE POLICY "Authenticated create comments" ON "public"."comments" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "author_id") AND ("deleted_at" IS NULL)));



CREATE POLICY "Authenticated create correction" ON "public"."climb_corrections" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "user_id")));



CREATE POLICY "Authenticated create correction vote" ON "public"."correction_votes" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "user_id")));



CREATE POLICY "Authenticated create crag report" ON "public"."crag_reports" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated create crag_images" ON "public"."crag_images" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated create crags" ON "public"."crags" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated create grade vote" ON "public"."grade_votes" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "user_id")));



CREATE POLICY "Authenticated create notifications" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated create own community comments" ON "public"."community_post_comments" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "author_id")));



CREATE POLICY "Authenticated create own community posts" ON "public"."community_posts" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "author_id")));



CREATE POLICY "Authenticated create places" ON "public"."places" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated create profile" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Authenticated create regions" ON "public"."regions" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated create route grade" ON "public"."route_grades" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "user_id")));



CREATE POLICY "Authenticated create verification" ON "public"."climb_verifications" FOR INSERT WITH CHECK ((("auth"."role"() = 'authenticated'::"text") AND ("auth"."uid"() = "user_id")));



CREATE POLICY "Authenticated delete own correction vote" ON "public"."correction_votes" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated delete own grade vote" ON "public"."grade_votes" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated delete own route grade" ON "public"."route_grades" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated delete own verification" ON "public"."climb_verifications" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated update own correction" ON "public"."climb_corrections" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated update own grade vote" ON "public"."grade_votes" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated update own route grade" ON "public"."route_grades" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Author soft delete comments" ON "public"."comments" FOR UPDATE USING ((("auth"."uid"() = "author_id") AND ("deleted_at" IS NULL))) WITH CHECK ((("auth"."uid"() = "author_id") AND ("deleted_at" IS NOT NULL)));



CREATE POLICY "Collaborators read shared images" ON "public"."images" FOR SELECT USING ("public"."is_submission_collaborator"("id", "auth"."uid"()));



CREATE POLICY "Gym members write gym route markers" ON "public"."gym_route_markers" USING ((EXISTS ( SELECT 1
   FROM ("public"."gym_routes" "gr"
     JOIN "public"."gym_memberships" "gm" ON (("gm"."gym_place_id" = "gr"."gym_place_id")))
  WHERE (("gr"."id" = "gym_route_markers"."route_id") AND ("gm"."user_id" = "auth"."uid"()) AND ("gm"."status" = 'active'::"text") AND ("gm"."role" = ANY (ARRAY['owner'::"text", 'manager'::"text", 'head_setter'::"text", 'setter'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."gym_routes" "gr"
     JOIN "public"."gym_memberships" "gm" ON (("gm"."gym_place_id" = "gr"."gym_place_id")))
  WHERE (("gr"."id" = "gym_route_markers"."route_id") AND ("gm"."user_id" = "auth"."uid"()) AND ("gm"."status" = 'active'::"text") AND ("gm"."role" = ANY (ARRAY['owner'::"text", 'manager'::"text", 'head_setter'::"text", 'setter'::"text"]))))));



CREATE POLICY "Gym members write gym routes" ON "public"."gym_routes" USING ((EXISTS ( SELECT 1
   FROM "public"."gym_memberships" "gm"
  WHERE (("gm"."user_id" = "auth"."uid"()) AND ("gm"."gym_place_id" = "gym_routes"."gym_place_id") AND ("gm"."status" = 'active'::"text") AND ("gm"."role" = ANY (ARRAY['owner'::"text", 'manager'::"text", 'head_setter'::"text", 'setter'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."gym_memberships" "gm"
  WHERE (("gm"."user_id" = "auth"."uid"()) AND ("gm"."gym_place_id" = "gym_routes"."gym_place_id") AND ("gm"."status" = 'active'::"text") AND ("gm"."role" = ANY (ARRAY['owner'::"text", 'manager'::"text", 'head_setter'::"text", 'setter'::"text"]))))));



CREATE POLICY "Owner add collaborators" ON "public"."submission_collaborators" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."images" "i"
  WHERE (("i"."id" = "submission_collaborators"."image_id") AND ("i"."created_by" = "auth"."uid"())))) AND ("created_by" = "auth"."uid"())));



CREATE POLICY "Owner create climb_video_betas" ON "public"."climb_video_betas" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner create climbs" ON "public"."climbs" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner create images" ON "public"."images" FOR INSERT WITH CHECK (("auth"."uid"() = "created_by"));



CREATE POLICY "Owner create invites" ON "public"."submission_collaborator_invites" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."images" "i"
  WHERE (("i"."id" = "submission_collaborator_invites"."image_id") AND ("i"."created_by" = "auth"."uid"())))) AND ("created_by" = "auth"."uid"())));



CREATE POLICY "Owner create route_lines" ON "public"."route_lines" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."climbs"
  WHERE (("climbs"."id" = "route_lines"."climb_id") AND ("climbs"."user_id" = "auth"."uid"())))));



CREATE POLICY "Owner create user_climbs" ON "public"."user_climbs" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner delete climb_video_betas" ON "public"."climb_video_betas" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner delete community comments" ON "public"."community_post_comments" FOR DELETE USING (("auth"."uid"() = "author_id"));



CREATE POLICY "Owner delete community posts" ON "public"."community_posts" FOR DELETE USING (("auth"."uid"() = "author_id"));



CREATE POLICY "Owner delete user_climbs" ON "public"."user_climbs" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner or collaborator read collaborators" ON "public"."submission_collaborators" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."images" "i"
  WHERE (("i"."id" = "submission_collaborators"."image_id") AND ("i"."created_by" = "auth"."uid"()))))));



CREATE POLICY "Owner read invites" ON "public"."submission_collaborator_invites" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."images" "i"
  WHERE (("i"."id" = "submission_collaborator_invites"."image_id") AND ("i"."created_by" = "auth"."uid"())))));



CREATE POLICY "Owner read own images" ON "public"."images" FOR SELECT USING (("auth"."uid"() = "created_by"));



CREATE POLICY "Owner read own user_climbs" ON "public"."user_climbs" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner remove collaborators" ON "public"."submission_collaborators" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."images" "i"
  WHERE (("i"."id" = "submission_collaborators"."image_id") AND ("i"."created_by" = "auth"."uid"())))));



CREATE POLICY "Owner revoke invites" ON "public"."submission_collaborator_invites" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."images" "i"
  WHERE (("i"."id" = "submission_collaborator_invites"."image_id") AND ("i"."created_by" = "auth"."uid"())))));



CREATE POLICY "Owner update climb_video_betas" ON "public"."climb_video_betas" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner update community comments" ON "public"."community_post_comments" FOR UPDATE USING (("auth"."uid"() = "author_id")) WITH CHECK (("auth"."uid"() = "author_id"));



CREATE POLICY "Owner update community posts" ON "public"."community_posts" FOR UPDATE USING (("auth"."uid"() = "author_id")) WITH CHECK (("auth"."uid"() = "author_id"));



CREATE POLICY "Owner update own pending climbs" ON "public"."climbs" FOR UPDATE USING ((("auth"."uid"() = "user_id") AND (("status")::"text" = 'pending'::"text"))) WITH CHECK ((("auth"."uid"() = "user_id") AND (("status")::"text" = 'pending'::"text")));



CREATE POLICY "Owner update profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Owner update user_climbs" ON "public"."user_climbs" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Public create gym owner applications" ON "public"."gym_owner_applications" FOR INSERT TO "authenticated", "anon" WITH CHECK (("auth"."role"() = ANY (ARRAY['anon'::"text", 'authenticated'::"text"])));



CREATE POLICY "Public read approved images" ON "public"."images" FOR SELECT USING ((COALESCE("moderation_status", 'pending'::"text") = 'approved'::"text"));



CREATE POLICY "Public read climb_flags" ON "public"."climb_flags" FOR SELECT USING (true);



CREATE POLICY "Public read climb_video_betas" ON "public"."climb_video_betas" FOR SELECT USING (true);



CREATE POLICY "Public read climbs" ON "public"."climbs" FOR SELECT USING (true);



CREATE POLICY "Public read community comments" ON "public"."community_post_comments" FOR SELECT USING (true);



CREATE POLICY "Public read community posts" ON "public"."community_posts" FOR SELECT USING (true);



CREATE POLICY "Public read community rsvps" ON "public"."community_post_rsvps" FOR SELECT USING (true);



CREATE POLICY "Public read correction votes" ON "public"."correction_votes" FOR SELECT USING (true);



CREATE POLICY "Public read corrections" ON "public"."climb_corrections" FOR SELECT USING (true);



CREATE POLICY "Public read crag reports" ON "public"."crag_reports" FOR SELECT USING (true);



CREATE POLICY "Public read crag_images" ON "public"."crag_images" FOR SELECT USING (true);



CREATE POLICY "Public read crags" ON "public"."crags" FOR SELECT USING (true);



CREATE POLICY "Public read grade mappings" ON "public"."grade_mappings" FOR SELECT USING (true);



CREATE POLICY "Public read grade votes" ON "public"."grade_votes" FOR SELECT USING (true);



CREATE POLICY "Public read grades" ON "public"."grades" FOR SELECT USING (true);



CREATE POLICY "Public read gym_floor_plans" ON "public"."gym_floor_plans" FOR SELECT USING (true);



CREATE POLICY "Public read gym_route_markers" ON "public"."gym_route_markers" FOR SELECT USING (true);



CREATE POLICY "Public read gym_routes" ON "public"."gym_routes" FOR SELECT USING (true);



CREATE POLICY "Public read places" ON "public"."places" FOR SELECT USING (true);



CREATE POLICY "Public read product clicks" ON "public"."product_clicks" FOR SELECT USING (true);



CREATE POLICY "Public read profiles" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Public read regions" ON "public"."regions" FOR SELECT USING (true);



CREATE POLICY "Public read route grades" ON "public"."route_grades" FOR SELECT USING (true);



CREATE POLICY "Public read route_lines" ON "public"."route_lines" FOR SELECT USING (true);



CREATE POLICY "Public read user_climbs for public profiles" ON "public"."user_climbs" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "user_climbs"."user_id") AND ("profiles"."is_public" = true)))));



CREATE POLICY "Public read verifications" ON "public"."climb_verifications" FOR SELECT USING (true);



CREATE POLICY "Public read visible comments" ON "public"."comments" FOR SELECT USING (("deleted_at" IS NULL));



CREATE POLICY "Service role manage deleted accounts" ON "public"."deleted_accounts" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role manage deletion requests" ON "public"."deletion_requests" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "User read own notifications" ON "public"."notifications" FOR SELECT USING ((("auth"."uid"() = "user_id") OR (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."is_admin" = true))))));



CREATE POLICY "User update own notifications" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can create deletion requests for themselves" ON "public"."deletion_requests" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own deletion requests" ON "public"."deletion_requests" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own deletion requests" ON "public"."deletion_requests" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users create own submission_draft_images" ON "public"."submission_draft_images" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."submission_drafts" "d"
  WHERE (("d"."id" = "submission_draft_images"."draft_id") AND ("d"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users create own submission_drafts" ON "public"."submission_drafts" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users delete own submission_draft_images" ON "public"."submission_draft_images" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."submission_drafts" "d"
  WHERE (("d"."id" = "submission_draft_images"."draft_id") AND ("d"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users delete own submission_drafts" ON "public"."submission_drafts" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own community rsvps" ON "public"."community_post_rsvps" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own deletion requests" ON "public"."deletion_requests" TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own place follows" ON "public"."community_place_follows" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users read own gym memberships" ON "public"."gym_memberships" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users read own place follows" ON "public"."community_place_follows" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users read own submission_draft_images" ON "public"."submission_draft_images" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."submission_drafts" "d"
  WHERE (("d"."id" = "submission_draft_images"."draft_id") AND ("d"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users read own submission_drafts" ON "public"."submission_drafts" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users update own submission_draft_images" ON "public"."submission_draft_images" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."submission_drafts" "d"
  WHERE (("d"."id" = "submission_draft_images"."draft_id") AND ("d"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."submission_drafts" "d"
  WHERE (("d"."id" = "submission_draft_images"."draft_id") AND ("d"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users update own submission_drafts" ON "public"."submission_drafts" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."admin_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."climb_corrections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."climb_flags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."climb_verifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."climb_video_betas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."climbs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_place_follows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_post_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_post_rsvps" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."correction_votes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crag_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crag_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."deleted_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."deletion_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."grade_mappings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."grade_votes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."grades" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gym_floor_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gym_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gym_owner_applications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gym_route_markers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gym_routes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."places" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_clicks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."regions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."route_grades" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."route_lines" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."submission_collaborator_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."submission_collaborators" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."submission_draft_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."submission_drafts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_climbs" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."add_correction_type_value"("new_value" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_correction_type_value"("new_value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_correction_type_value"("new_value" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_submission_collaborator_invite"("p_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_submission_collaborator_invite"("p_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."claim_submission_collaborator_invite"("p_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_submission_collaborator_invite"("p_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_orphan_route_uploads"("max_age" interval, "max_delete" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_orphan_route_uploads"("max_age" interval, "max_delete" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_orphan_route_uploads"("max_age" interval, "max_delete" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_orphan_route_uploads"("max_age" interval, "max_delete" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."climbs_recompute_crag_location_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."climbs_recompute_crag_location_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."climbs_recompute_crag_location_trigger"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_submission_routes_atomic"("p_image_id" "uuid", "p_crag_id" "uuid", "p_route_type" "text", "p_routes" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_submission_routes_atomic"("p_image_id" "uuid", "p_crag_id" "uuid", "p_route_type" "text", "p_routes" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_submission_routes_atomic"("p_image_id" "uuid", "p_crag_id" "uuid", "p_route_type" "text", "p_routes" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_submission_routes_atomic"("p_image_id" "uuid", "p_crag_id" "uuid", "p_route_type" "text", "p_routes" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_unified_submission_atomic"("p_crag_id" "uuid", "p_primary_image" "jsonb", "p_supplementary_images" "jsonb"[], "p_routes" "jsonb", "p_route_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_unified_submission_atomic"("p_crag_id" "uuid", "p_primary_image" "jsonb", "p_supplementary_images" "jsonb"[], "p_routes" "jsonb", "p_route_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_unified_submission_atomic"("p_crag_id" "uuid", "p_primary_image" "jsonb", "p_supplementary_images" "jsonb"[], "p_routes" "jsonb", "p_route_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_unified_submission_atomic"("p_crag_id" "uuid", "p_primary_image" "jsonb", "p_supplementary_images" "jsonb"[], "p_routes" "jsonb", "p_route_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_empty_crag"("target_crag_id" "uuid", "grace_period" interval) TO "anon";
GRANT ALL ON FUNCTION "public"."delete_empty_crag"("target_crag_id" "uuid", "grace_period" interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_empty_crag"("target_crag_id" "uuid", "grace_period" interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_empty_crags"("grace_period" interval) TO "anon";
GRANT ALL ON FUNCTION "public"."delete_empty_crags"("grace_period" interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_empty_crags"("grace_period" interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_comment_soft_delete_only"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_comment_soft_delete_only"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_comment_soft_delete_only"() TO "service_role";



GRANT ALL ON FUNCTION "public"."find_region_by_location"("search_lat" double precision, "search_lng" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."find_region_by_location"("search_lat" double precision, "search_lng" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."find_region_by_location"("search_lat" double precision, "search_lng" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_active_climbers_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_active_climbers_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_active_climbers_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_boulders_with_gps_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_boulders_with_gps_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_boulders_with_gps_count"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_climb_full_context"("p_climb_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_climb_full_context"("p_climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_climb_full_context"("p_climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_climb_full_context"("p_climb_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_climbs_with_consensus"("p_climb_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_climbs_with_consensus"("p_climb_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_climbs_with_consensus"("p_climb_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_community_photos_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_community_photos_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_community_photos_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_consensus_grade"("climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_consensus_grade"("climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_consensus_grade"("climb_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_crag_faces_complete_summary"("p_image_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_crag_faces_complete_summary"("p_image_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_crag_faces_complete_summary"("p_image_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_crag_faces_complete_summary"("p_image_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_crag_pins"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_crag_pins"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_crag_pins"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_crag_pins"("include_pending" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_crag_pins"("include_pending" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_crag_pins"("include_pending" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_grade_vote_distribution"("climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_grade_vote_distribution"("climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_grade_vote_distribution"("climb_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_image_faces_summary"("p_image_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_image_faces_summary"("p_image_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_image_faces_summary"("p_image_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_image_faces_summary"("p_image_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_star_rating_summary"("p_climb_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_star_rating_summary"("p_climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_star_rating_summary"("p_climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_star_rating_summary"("p_climb_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_total_climbs_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_total_climbs_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_total_climbs_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_total_logs_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_total_logs_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_total_logs_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_total_sends_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_total_sends_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_total_sends_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_verification_count"("climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_verification_count"("climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_verification_count"("climb_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_verified_routes_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_verified_routes_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_verified_routes_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."grade_votes_sync_climb_grade_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."grade_votes_sync_climb_grade_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."grade_votes_sync_climb_grade_trigger"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_metadata_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_metadata_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_metadata_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."images_recompute_crag_location_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."images_recompute_crag_location_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."images_recompute_crag_location_trigger"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_crag_report_count"("target_crag_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_crag_report_count"("target_crag_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_crag_report_count"("target_crag_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."increment_gear_click"("product_id_input" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."increment_gear_click"("product_id_input" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_gear_click"("product_id_input" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_gear_click"("product_id_input" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."initialize_climb_consensus"() TO "anon";
GRANT ALL ON FUNCTION "public"."initialize_climb_consensus"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."initialize_climb_consensus"() TO "service_role";



GRANT ALL ON FUNCTION "public"."initialize_climb_grade_vote"("p_climb_id" "uuid", "p_user_id" "uuid", "p_grade" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."initialize_climb_grade_vote"("p_climb_id" "uuid", "p_user_id" "uuid", "p_grade" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."initialize_climb_grade_vote"("p_climb_id" "uuid", "p_user_id" "uuid", "p_grade" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_grade_vote"("p_climb_id" "uuid", "vote_grade" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."insert_grade_vote"("p_climb_id" "uuid", "vote_grade" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_grade_vote"("p_climb_id" "uuid", "vote_grade" character varying) TO "service_role";



GRANT ALL ON TABLE "public"."crag_images" TO "anon";
GRANT ALL ON TABLE "public"."crag_images" TO "authenticated";
GRANT ALL ON TABLE "public"."crag_images" TO "service_role";



REVOKE ALL ON FUNCTION "public"."insert_pin_images_atomic"("p_crag_id" "uuid", "p_urls" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."insert_pin_images_atomic"("p_crag_id" "uuid", "p_urls" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."insert_pin_images_atomic"("p_crag_id" "uuid", "p_urls" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_pin_images_atomic"("p_crag_id" "uuid", "p_urls" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_climb_verified"("climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_climb_verified"("climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_climb_verified"("climb_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_profile_public"("user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_profile_public"("user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_profile_public"("user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_submission_collaborator"("p_image_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_submission_collaborator"("p_image_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_submission_collaborator"("p_image_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_submission_collaborator"("p_image_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_climb_route_type"("raw_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_climb_route_type"("raw_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_climb_route_type"("raw_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."patch_submission_draft_images_atomic"("p_draft_id" "uuid", "p_images" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."patch_submission_draft_images_atomic"("p_draft_id" "uuid", "p_images" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."patch_submission_draft_images_atomic"("p_draft_id" "uuid", "p_images" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."patch_submission_draft_images_atomic"("p_draft_id" "uuid", "p_images" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_climb_location_from_image"() TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_climb_location_from_image"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_climb_location_from_image"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_crag_counts"() TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_crag_counts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_crag_counts"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_crag_location"("target_crag_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_crag_location"("target_crag_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_crag_location"("target_crag_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_crag_type_from_climbs"("target_crag_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_crag_type_from_climbs"("target_crag_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_crag_type_from_climbs"("target_crag_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."slugify"("input" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."slugify"("input" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."slugify"("input" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."soft_delete_comment"("p_comment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."soft_delete_comment"("p_comment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."soft_delete_comment"("p_comment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."soft_delete_comment"("p_comment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_climb_grade_from_votes"("p_climb_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sync_climb_grade_from_votes"("p_climb_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_climb_grade_from_votes"("p_climb_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_crag_to_place"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_crag_to_place"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_crag_to_place"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_crag_type_from_climbs"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_crag_type_from_climbs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_crag_type_from_climbs"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_place_to_crag"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_place_to_crag"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_place_to_crag"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_profile_on_login"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_profile_on_login"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_profile_on_login"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_submission_draft_images_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_submission_draft_images_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_submission_draft_images_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_submission_drafts_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_submission_drafts_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_submission_drafts_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_recompute_crag_counts_climbs"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_recompute_crag_counts_climbs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_recompute_crag_counts_climbs"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_recompute_crag_counts_images"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_recompute_crag_counts_images"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_recompute_crag_counts_images"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_climb_consensus"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_climb_consensus"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_climb_consensus"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_climb_consensus_safe"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_climb_consensus_safe"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_climb_consensus_safe"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_own_profile_submission_credit"("p_platform" "text", "p_handle" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_own_profile_submission_credit"("p_platform" "text", "p_handle" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_own_profile_submission_credit"("p_platform" "text", "p_handle" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_own_profile_submission_credit"("p_platform" "text", "p_handle" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_own_submission_credit"("p_image_id" "uuid", "p_platform" "text", "p_handle" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_own_submission_credit"("p_image_id" "uuid", "p_platform" "text", "p_handle" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_own_submission_credit"("p_image_id" "uuid", "p_platform" "text", "p_handle" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_own_submission_credit"("p_image_id" "uuid", "p_platform" "text", "p_handle" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_own_submitted_routes"("p_image_id" "uuid", "p_routes" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_own_submitted_routes"("p_image_id" "uuid", "p_routes" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_own_submitted_routes"("p_image_id" "uuid", "p_routes" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_own_submitted_routes"("p_image_id" "uuid", "p_routes" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_submission_image_metadata"("p_image_id" "uuid", "p_latitude" double precision, "p_longitude" double precision, "p_face_directions" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_submission_image_metadata"("p_image_id" "uuid", "p_latitude" double precision, "p_longitude" double precision, "p_face_directions" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."update_submission_image_metadata"("p_image_id" "uuid", "p_latitude" double precision, "p_longitude" double precision, "p_face_directions" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_submission_image_metadata"("p_image_id" "uuid", "p_latitude" double precision, "p_longitude" double precision, "p_face_directions" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_comment_target"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_comment_target"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_comment_target"() TO "service_role";
























GRANT SELECT,MAINTAIN ON TABLE "public"."admin_actions" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."admin_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_actions" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."climb_corrections" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."climb_corrections" TO "authenticated";
GRANT ALL ON TABLE "public"."climb_corrections" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."climb_flags" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."climb_flags" TO "authenticated";
GRANT ALL ON TABLE "public"."climb_flags" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."climb_verifications" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."climb_verifications" TO "authenticated";
GRANT ALL ON TABLE "public"."climb_verifications" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."climb_video_betas" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."climb_video_betas" TO "authenticated";
GRANT ALL ON TABLE "public"."climb_video_betas" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."climbs" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."climbs" TO "authenticated";
GRANT ALL ON TABLE "public"."climbs" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."comments" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."community_place_follows" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."community_place_follows" TO "authenticated";
GRANT ALL ON TABLE "public"."community_place_follows" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."community_post_comments" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."community_post_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."community_post_comments" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."community_post_rsvps" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."community_post_rsvps" TO "authenticated";
GRANT ALL ON TABLE "public"."community_post_rsvps" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."community_posts" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."community_posts" TO "authenticated";
GRANT ALL ON TABLE "public"."community_posts" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."correction_votes" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."correction_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."correction_votes" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."crag_reports" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."crag_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."crag_reports" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."crags" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."crags" TO "authenticated";
GRANT ALL ON TABLE "public"."crags" TO "service_role";



GRANT MAINTAIN ON TABLE "public"."deleted_accounts" TO "anon";
GRANT MAINTAIN ON TABLE "public"."deleted_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."deleted_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."deletion_requests" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."deletion_requests" TO "authenticated";



GRANT ALL ON TABLE "public"."grade_mappings" TO "anon";
GRANT ALL ON TABLE "public"."grade_mappings" TO "authenticated";
GRANT ALL ON TABLE "public"."grade_mappings" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."grade_votes" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."grade_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."grade_votes" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."grades" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."grades" TO "authenticated";
GRANT ALL ON TABLE "public"."grades" TO "service_role";



GRANT ALL ON TABLE "public"."gym_floor_plans" TO "anon";
GRANT ALL ON TABLE "public"."gym_floor_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."gym_floor_plans" TO "service_role";



GRANT ALL ON TABLE "public"."gym_memberships" TO "anon";
GRANT ALL ON TABLE "public"."gym_memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."gym_memberships" TO "service_role";



GRANT ALL ON TABLE "public"."gym_owner_applications" TO "anon";
GRANT ALL ON TABLE "public"."gym_owner_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."gym_owner_applications" TO "service_role";



GRANT ALL ON TABLE "public"."gym_route_markers" TO "anon";
GRANT ALL ON TABLE "public"."gym_route_markers" TO "authenticated";
GRANT ALL ON TABLE "public"."gym_route_markers" TO "service_role";



GRANT ALL ON TABLE "public"."gym_routes" TO "anon";
GRANT ALL ON TABLE "public"."gym_routes" TO "authenticated";
GRANT ALL ON TABLE "public"."gym_routes" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."images" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."images" TO "authenticated";
GRANT ALL ON TABLE "public"."images" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."notifications" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."places" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."places" TO "authenticated";
GRANT ALL ON TABLE "public"."places" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."product_clicks" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."product_clicks" TO "authenticated";
GRANT ALL ON TABLE "public"."product_clicks" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."profiles" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."regions" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."regions" TO "authenticated";
GRANT ALL ON TABLE "public"."regions" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."route_grades" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."route_grades" TO "authenticated";
GRANT ALL ON TABLE "public"."route_grades" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."route_lines" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."route_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."route_lines" TO "service_role";



GRANT ALL ON TABLE "public"."submission_collaborator_invites" TO "anon";
GRANT ALL ON TABLE "public"."submission_collaborator_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."submission_collaborator_invites" TO "service_role";



GRANT ALL ON TABLE "public"."submission_collaborators" TO "anon";
GRANT ALL ON TABLE "public"."submission_collaborators" TO "authenticated";
GRANT ALL ON TABLE "public"."submission_collaborators" TO "service_role";



GRANT ALL ON TABLE "public"."submission_draft_images" TO "anon";
GRANT ALL ON TABLE "public"."submission_draft_images" TO "authenticated";
GRANT ALL ON TABLE "public"."submission_draft_images" TO "service_role";



GRANT ALL ON TABLE "public"."submission_drafts" TO "anon";
GRANT ALL ON TABLE "public"."submission_drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."submission_drafts" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."user_climbs" TO "anon";
GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE "public"."user_climbs" TO "authenticated";
GRANT ALL ON TABLE "public"."user_climbs" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
































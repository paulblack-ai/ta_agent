-- ============================================================
-- Brokerage Transactions + RAG + Compliance (Supabase/Postgres)
-- ============================================================

-- 0) Extensions
create extension if not exists pgcrypto;
create extension if not exists vector;

-- 1) Schemas
create schema if not exists core;
create schema if not exists ai;
create schema if not exists compliance;

-- 2) Enums
do $$
begin
  if not exists (select 1 from pg_type where typname='party_role') then
    create type party_role as enum (
      'buyer','seller','listing_agent','selling_agent',
      'closing_agency','earnest_money_holder','lender','other'
    );
  end if;

  if not exists (select 1 from pg_type where typname='doc_type') then
    create type doc_type as enum ('psa','addendum','disclosure','inspection','audit_trail','other');
  end if;

  if not exists (select 1 from pg_type where typname='financing_type') then
    create type financing_type as enum ('cash','conventional','fha','va','usda','thda','other','unspecified');
  end if;

  if not exists (select 1 from pg_type where typname='appraisal_contingency') then
    create type appraisal_contingency as enum ('not_contingent','contingent','unspecified');
  end if;

  if not exists (select 1 from pg_type where typname='ingest_source') then
    create type ingest_source as enum ('email','upload','slack','folder','crm','api','other');
  end if;

  if not exists (select 1 from pg_type where typname='check_severity') then
    create type check_severity as enum ('low','medium','high','critical');
  end if;

  if not exists (select 1 from pg_type where typname='check_status') then
    create type check_status as enum ('pass','fail','warn','na','pending');
  end if;

  if not exists (select 1 from pg_type where typname='txn_status') then
    create type txn_status as enum ('draft','open','pending_hitl','blocked','ready_to_close','closed','void');
  end if;
end$$;

-- 3) Helper: updated_at trigger
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end$$;

-- 4) Core tables
create table if not exists core.transactions (
  id uuid primary key default gen_random_uuid(),
  deal_code text unique,                               -- human code (e.g., TRX-2025-000312)

  -- property
  property_address text,
  property_unit text,
  property_city text,
  property_state text,
  property_zip text,
  property_county text,

  -- economics
  purchase_price numeric(12,2) check (purchase_price is null or purchase_price >= 0),
  currency char(3) default 'USD',
  financing financing_type default 'unspecified',
  appraisal appraisal_contingency default 'unspecified',

  -- earnest money
  earnest_money_amount numeric(12,2) check (earnest_money_amount is null or earnest_money_amount >= 0),
  earnest_money_due_days int check (earnest_money_due_days is null or earnest_money_due_days >= 0),
  earnest_money_holder_name text,
  earnest_money_holder_address text,

  -- key dates
  binding_agreement_date date,
  closing_date date,

  -- form metadata
  form_name text default 'RF401 – Purchase and Sale Agreement',
  form_version text,
  special_stipulations text[],                          -- each stip as element
  source_doc_id uuid,                                   -- initial PSA doc FK set after documents exists

  -- lifecycle
  status txn_status default 'open',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_transactions_touch
before update on core.transactions
for each row execute function public.touch_updated_at();

create index if not exists idx_txn_city_state_zip on core.transactions(property_city,property_state,property_zip);
create index if not exists idx_txn_price on core.transactions(purchase_price);

create table if not exists core.parties (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references core.transactions(id) on delete cascade,
  role party_role not null,
  full_name text not null,
  firm text,
  license_no text,
  email text,
  phone text,
  address text,

  created_at timestamptz not null default now()
);
create index if not exists idx_parties_txn_role on core.parties(transaction_id, role);

create table if not exists core.documents (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid references core.transactions(id) on delete cascade,
  doc_type doc_type not null,
  title text,
  storage_url text,               -- Supabase Storage/external URL
  sha256 text,                    -- content hash (optional but recommended)
  page_count int,
  received_via ingest_source,
  received_at timestamptz default now(),

  -- e-sign metadata
  esign_provider text,
  esign_package_id text,

  -- raw text (optional; you may prefer storing only chunks)
  raw_text text,

  -- simple versioning
  version_no int default 1,
  supersedes_document_id uuid references core.documents(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_documents_touch
before update on core.documents
for each row execute function public.touch_updated_at();

-- link transaction.source_doc_id now that documents exists
alter table core.transactions
  add constraint if not exists transactions_source_doc_fk
  foreign key (source_doc_id) references core.documents(id) on delete set null;

create index if not exists idx_docs_txn on core.documents(transaction_id);
create index if not exists idx_docs_sha on core.documents(sha256);

-- field-level extractions
create table if not exists core.doc_fields (
  id bigserial primary key,
  document_id uuid not null references core.documents(id) on delete cascade,
  page int,
  field_name text not null,
  field_value_text text,
  field_value_num numeric,
  field_value_date date,
  confidence real check (confidence is null or (confidence >= 0 and confidence <= 1)),
  created_at timestamptz not null default now()
);
create index if not exists idx_doc_fields_doc on core.doc_fields(document_id);
create index if not exists idx_doc_fields_name on core.doc_fields(field_name);

-- e-sign audit events
create table if not exists core.esign_events (
  id bigserial primary key,
  document_id uuid not null references core.documents(id) on delete cascade,
  signer_name text,
  signer_email text,
  action text,                         -- viewed/signed/etc
  ip_address text,
  occurred_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_esign_doc on core.esign_events(document_id);

-- timeline / status events
create table if not exists core.timeline_events (
  id bigserial primary key,
  transaction_id uuid not null references core.transactions(id) on delete cascade,
  event_key text not null,            -- e.g., 'emd_due','inspection_scheduled'
  event_title text,
  event_time timestamptz,
  payload jsonb,
  created_by text,                    -- system/agent/bot
  created_at timestamptz not null default now()
);
create index if not exists idx_timeline_txn_key on core.timeline_events(transaction_id, event_key);

-- communications (email/slack logs with privacy filters applied upstream)
create table if not exists core.communication_logs (
  id bigserial primary key,
  transaction_id uuid references core.transactions(id) on delete cascade,
  channel text,                       -- email, slack, sms
  direction text,                     -- inbound/outbound
  sender text,
  recipients text[],
  subject text,
  body text,
  occurred_at timestamptz,
  redact_level int default 0,         -- 0 none, 1 pii redacted, 2 legal redacted
  created_at timestamptz not null default now()
);
create index if not exists idx_comm_txn_time on core.communication_logs(transaction_id, occurred_at);

-- 5) AI (pgvector)
-- Choose dimension to match your embedder (1536 for text-embedding-3-small)
create table if not exists ai.document_chunks (
  id bigserial primary key,
  document_id uuid not null references core.documents(id) on delete cascade,
  chunk_index int not null,
  content text not null,
  embedding vector(1536),
  tokens int,
  created_at timestamptz not null default now()
);

-- Cosine distance index (good default for text embeddings)
create index if not exists document_chunks_embedding_idx
  on ai.document_chunks
  using ivfflat (embedding vector_cosine_ops)
  with (lists = 100);

-- Simple similarity search
create or replace function ai.match_document_chunks(
  query_embedding vector(1536),
  match_count int default 20,
  min_content_length int default 20
)
returns table(
  document_id uuid,
  chunk_index int,
  content text,
  similarity float
) language sql stable as $$
  select dc.document_id, dc.chunk_index, dc.content,
         1 - (dc.embedding <=> query_embedding) as similarity
  from ai.document_chunks dc
  where length(dc.content) >= min_content_length
  order by dc.embedding <=> query_embedding
  limit match_count;
$$;

-- Human-readable "deal facts" for retrieval
create or replace view ai.rag_deal_facts as
select
  t.id as transaction_id,
  concat_ws(
    E'\n',
    'Deal Code: ' || coalesce(t.deal_code,''),
    'Address: '   || coalesce(t.property_address,'') ||
                   case when t.property_unit is not null then ' '||t.property_unit else '' end || ', ' ||
                   coalesce(t.property_city,'') || ', ' ||
                   coalesce(t.property_state,'') || ' ' ||
                   coalesce(t.property_zip,''),
    'County: '    || coalesce(t.property_county,''),
    'Price: $'    || coalesce(to_char(t.purchase_price, 'FM999,999,990.00'),''),
    'Financing: ' || coalesce(t.financing::text,'unspecified'),
    'Appraisal: ' || coalesce(t.appraisal::text,'unspecified'),
    'EMD: $'      || coalesce(to_char(t.earnest_money_amount, 'FM999,999,990.00'),'') ||
                   ' due in ' || coalesce(t.earnest_money_due_days::text,'?') || ' days' ||
                   ' (Holder: ' || coalesce(t.earnest_money_holder_name,'') || ')',
    'Closing Date: ' || coalesce(t.closing_date::text,'unspecified'),
    'Form Version: ' || coalesce(t.form_version,''),
    'Special Stipulations: ' ||
      case when t.special_stipulations is null or cardinality(t.special_stipulations)=0
           then '(none)'
           else array_to_string(t.special_stipulations, '; ')
      end
  ) as content
from core.transactions t;

-- 6) Compliance
create table if not exists compliance.check_definitions (
  id uuid primary key default gen_random_uuid(),
  key text unique not null,                -- 'emd_timeline', 'cash_proof_letter', ...
  title text not null,
  description text,
  severity check_severity not null default 'medium',
  resolver_hint text,
  created_at timestamptz not null default now()
);

-- Optional: group checks by state/board/package
create table if not exists compliance.rule_packs (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,               -- e.g., 'TN_RES_2025'
  title text not null,
  jurisdiction text,                       -- state/MLS
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists compliance.rule_pack_checks (
  rule_pack_id uuid not null references compliance.rule_packs(id) on delete cascade,
  check_key text not null references compliance.check_definitions(key) on delete cascade,
  weight numeric(6,2) default 1.0,
  primary key (rule_pack_id, check_key)
);

create table if not exists compliance.check_results (
  id bigserial primary key,
  transaction_id uuid not null references core.transactions(id) on delete cascade,
  document_id uuid references core.documents(id) on delete set null,
  check_key text not null references compliance.check_definitions(key) on delete cascade,
  status check_status not null default 'pending',
  details jsonb,                           -- {due_by:'2025-09-01', holder:'East Realty', reason:'missing letter'}
  created_at timestamptz not null default now()
);
create index if not exists idx_compliance_txn_key on compliance.check_results(transaction_id, check_key);

-- roll-up of transaction status (separate from core.transactions.status if you want both)
create table if not exists compliance.transaction_status (
  transaction_id uuid primary key references core.transactions(id) on delete cascade,
  status txn_status not null default 'open',
  updated_at timestamptz not null default now()
);

-- 7) Seeds (optional)
insert into compliance.check_definitions(key,title,description,severity,resolver_hint) values
  ('emd_timeline','Earnest Money due on time','Due N days from binding','high','Verify receipt and date'),
  ('cash_proof_letter','Proof of funds letter attached','Cash requires bank letter','medium','Request letter from buyer'),
  ('appraisal_marked','Appraisal contingency marked','Confirm appraisal selection or addendum','medium','Add proper addendum if needed')
on conflict (key) do nothing;

-- 8) Helpful view: last compliance status per check on a transaction
create or replace view compliance.v_last_check_status as
with ranked as (
  select
    cr.*,
    row_number() over (partition by transaction_id, check_key order by created_at desc) rn
  from compliance.check_results cr
)
select * from ranked where rn = 1;

-- 9) Notes
-- - After inserting/changing many embeddings: ANALYZE ai.document_chunks;
-- - If you plan to enforce RLS, prefer Supabase REST/RPC and define policies.
--   (Direct Postgres connections from n8n won’t use JWT claims; adjust accordingly.)
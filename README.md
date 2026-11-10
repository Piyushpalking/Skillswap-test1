
# SkillSwap

A skill-exchange platform where people teach what they know and learn what they want.

## Tech stack

- HTML, CSS and JavaScript
- Supabase Authentication
- Supabase PostgreSQL
- Row Level Security
- PostgreSQL RPC matching engine
- Netlify static hosting

## Setup

### 1. Create Supabase project

Visit https://supabase.com and create a project.

### 2. Configure database

Open Supabase Dashboard → SQL Editor.

Paste the complete `supabase/schema.sql` file and execute it.

### 3. Configure frontend

Open `config.js`.

Replace:

- YOUR_SUPABASE_PROJECT_URL
- YOUR_SUPABASE_ANON_KEY

with the Project URL and public anon/publishable key from Supabase.

Never put the service_role key in frontend code.

### 4. Configure authentication

In Supabase:

Authentication → URL Configuration

Set your Site URL to your deployed Netlify URL.

Add your Netlify URL to the Redirect URLs allowlist.

### 5. Deploy to Netlify

1. Keep all files inside the SkillSwap folder.
2. Open Netlify Drop.
3. Drag and drop the folder containing index.html.
4. Wait for deployment.
5. Open the generated website URL.

## Project structure

SkillSwap/
- index.html
- style.css
- app.js
- config.js
- netlify.toml
- README.md
- supabase/schema.sql

## Important

This project requires a configured Supabase backend.
Netlify Drop only hosts the frontend.

Test authentication, RLS policies, matching, requests and messaging with at least two separate accounts before public launch.

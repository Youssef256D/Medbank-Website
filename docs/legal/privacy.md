---
title: Privacy Policy
slug: privacy
effectiveDate: 2026-06-30
summary: How MedBank collects, uses, protects, and retains account, course, practice, and support data.
---

# Privacy Policy

Effective date: June 30, 2026

MedBank is a browser-based study platform for medical MCQ practice and course
learning. This Privacy Policy explains what information MedBank collects, how it
is used, and the choices available to students, administrators, and visitors.

## Who this policy covers

This policy applies when you visit MedBank, create an account, sign in, complete
practice sessions, use course materials, contact support, or administer courses
and users.

MedBank is designed for study and education. It is not a medical-care service,
electronic health record, clinical decision system, or emergency support channel.
Do not submit patient-identifiable health information unless an authorized
administrator has specifically approved that workflow.

## Information we collect

We collect the information needed to provide accounts, course access, practice
history, review tools, and support.

Account and profile information may include your name, email address, role,
phone number if you provide it, academic year, semester, approval status, course
assignments, and authentication identifiers from Supabase Auth or an enabled
sign-in provider such as Google.

Study and progress information may include assigned courses and topics, created
test blocks, question responses, score summaries, time spent, flags, notes,
incorrect queues, review history, analytics, notification status, and autosaved
in-progress sessions.

Course-platform information may include course enrollment requests, lesson
progress, course materials, protected video access records, and activity needed
to make course content available.

Admin and moderation information may include question-bank edits, imports,
course changes, user-management actions, announcements, access decisions,
admin-agent actions, approval requests, and audit logs.

Support information may include the name, email address, message, and context
you submit through MedBank support or contact forms.

Device and technical information may include browser type, device type, IP-based
network information available to hosting providers, session state, app version,
local cache state, service-worker cache status, and basic error or diagnostic
information needed to keep the app working.

## How we use information

We use information to:

- create and secure user accounts;
- verify student approval and course access;
- show assigned course banks, questions, explanations, and learning materials;
- save in-progress and completed practice sessions;
- produce analytics, weak-topic summaries, and review lists;
- let administrators manage users, courses, questions, notifications, and
  access;
- respond to support requests and investigate reported problems;
- protect the service from abuse, unauthorized access, accidental data loss, and
  unsafe content changes;
- maintain, debug, and improve MedBank.

We do not sell personal information.

## Storage and service providers

MedBank is a static web app served from GitHub Pages. Account, course, question,
progress, enrollment, notification, support, and admin data are stored in the
hosted Supabase project. Supabase Auth handles account authentication. Supabase
Edge Functions handle sensitive admin actions and protected course-video flows.

If Google sign-in is enabled and you choose to use it, Google may provide basic
authentication information such as your email address and profile name so
MedBank can create or access your account.

If protected course videos are used, Cloudflare Stream may be used to store or
deliver video content and issue short-lived playback tokens.

Your browser may store local cache data for route memory, theme preference,
offline safety, pending writes, and faster page loading. Browser storage is a
convenience layer; hosted Supabase is the source of truth for account, course,
question, enrollment, and progress data.

## Retention

Active account, enrollment, course-progress, and study records are kept while
the account is in use. After a verified account-deletion request, active account
data is normally deleted within 30 days.

Previous-test history is automatically limited to the most recent 20 days.
Older previous-test entries are pruned from hosted history and matching session
backup payloads.

Limited support, security, fraud-prevention, audit, legal, and residual backup
records may be retained for up to 90 days after deletion, then deleted or
anonymized. A record may be retained longer only when required by law. Shared
course and question-bank content that is not personal to the deleted account may
remain so it stays available to other users.

## Sharing

We share information only as needed to operate MedBank:

- with service providers that host, authenticate, store, secure, or deliver the
  app;
- with authorized administrators who manage users, courses, question banks,
  access, support, and academic workflows;
- when required to comply with law, protect rights and safety, investigate
  abuse, or enforce the Terms of Service;
- with your direction or consent.

We do not publish individual student performance data as a public leaderboard.

## Security

MedBank uses hosted Supabase authentication, row-level security, restricted admin
functions, and browser-safe public keys in the frontend. Secret keys belong only
in server-side functions and are not stored in public frontend files.

No online service can guarantee perfect security. Use a strong password, keep
your email account secure, sign out on shared devices, and report suspicious
activity through support.

## Your choices

You can update profile details where MedBank provides account settings. You can
request help correcting account, course, or access information through support.
You can request account and data deletion using the Data Deletion Instructions.
You can clear local browser storage from your browser settings, though doing so
may remove local preferences or unsynced offline data.

## Children

MedBank is intended for medical students, faculty, administrators, and authorized
education users. It is not directed to children under 13. If you believe a child
has created an account without appropriate authorization, contact support so the
account can be reviewed.

## Changes

We may update this Privacy Policy as MedBank changes. When changes are material,
we will update the effective date and make the new policy available through the
public legal pages.

## Contact

For privacy questions, account corrections, or deletion requests, email
`Code.Youssefaayoub@gmail.com` from the address associated with your account or
use the MedBank Contact page. Full instructions are published at
`https://youssef256d.github.io/Medbank-Website/deletion.html`.

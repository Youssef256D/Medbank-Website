window.__SUPABASE_CONFIG = {
  // Online Supabase is the single source of truth for this app.
  // Keep this as the hosted project HTTPS URL, not a local URL or Postgres connection string.
  url: "https://fzjzjzdamehxbgikiskt.supabase.co",
  // Browser-safe publishable key for supabase-js in the app.
  anonKey: "sb_publishable_h0rAeFDW-_yQA3EGqay-hA_wcupylm0",
  // Legacy anon key for Edge Function fallback calls when verify_jwt = true.
  legacyAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ6anpqemRhbWVoeGJnaWtpc2t0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5MjMwOTQsImV4cCI6MjA4NjQ5OTA5NH0.UG0lHcGojsBn-VtCVHD8jQdE9kd0dPrE68Hs4quLax0",
  enabled: true,
  onlineOnly: true,
  // Optional API base for server functions (example: https://your-api.vercel.app/api).
  // Leave empty for GitHub Pages-only deploys or when using Supabase Edge Functions fallback.
  serverApiBaseUrl: "",
  // Optional override for OAuth callbacks; keep this aligned with Supabase Auth redirect URLs.
  authRedirectUrl: "https://youssef256d.github.io/Medbank-Website/",
  // Native mobile deep link. Add this exact value in Supabase:
  // Authentication -> URL Configuration -> Redirect URLs
  mobileAuthRedirectUrl: "medbank://auth/callback",
  // Set true in the native wrapper before main.js loads if the mobile app is
  // served from the web URL but should still use the native callback scheme.
  forceMobileAuthRedirect: false,
  // Optional storage bucket for uploaded question images.
  questionImageBucket: "question-images",
  // Optional private storage bucket for uploaded course lesson videos.
  courseVideoBucket: "course-videos",
  // Optional private storage bucket for uploaded course cover images.
  courseCoverBucket: "course-covers",
  // Optional private storage bucket for uploaded lesson materials.
  courseMaterialBucket: "course-materials",
  // Free fallback: use private Supabase Storage for course videos.
  // Set this to true later when Cloudflare Stream billing is available.
  cloudflareStreamEnabled: false,
};

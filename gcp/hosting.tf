# The frontend on Firebase Hosting.
#
# Firebase Hosting replaces three AWS pieces at once: S3 holds the files, CloudFront is the CDN,
# and ACM plus the distribution's certificate config become one managed certificate nobody
# configures. The free plan is 10 GB stored and 360 MB a day transferred - the built SPA is
# about 1 MB, so a day of class demos is nowhere near it.
#
# What Terraform does *not* do here is upload the files. Hosting deploys are content releases,
# not infrastructure, and the tool for them is the Firebase CLI reading firebase.json:
#
#   cd front && npm run build
#   firebase deploy --only hosting --project <project id>
#
# firebase.json also carries the rewrite that sends /api/** to Cloud Run, which gives the site
# one origin and therefore no CORS at all - exactly what the CloudFront behaviour did in Lab 4.

resource "google_firebase_project" "main" {
  provider = google-beta
  project  = var.project_id

  depends_on = [google_project_service.enabled]
}

resource "google_firebase_hosting_site" "main" {
  provider = google-beta
  project  = var.project_id
  site_id  = "${var.project_name}-${var.project_id}"

  depends_on = [google_firebase_project.main]
}

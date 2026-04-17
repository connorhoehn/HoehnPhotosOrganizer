"""
cloudfront_albums.py — CloudFront distribution for shared album delivery.

STATUS: Phase 2 placeholder — not yet implemented.

Plan:
    - CloudFront distribution with OAC (Origin Access Control) fronting the
      existing HoehnPhotos S3 bucket (HoehnPhotosPrivateBucket).
    - Cache behaviors:
        proxies/*   — immutable assets, Cache-Control: max-age=31536000 (1 year)
        albums/*    — album manifests, Cache-Control: max-age=300 (5 minutes)
    - Custom domain (e.g. photos.hoehn.dev) with ACM certificate in us-east-1.
    - OAC replaces the legacy OAI pattern — grants CloudFront read-only access
      to the bucket without making the bucket public.

Prerequisites before implementing:
    1. Register or confirm the custom domain.
    2. Create an ACM certificate in us-east-1 (CloudFront requires us-east-1).
    3. Add a Route 53 alias record pointing the custom domain to the distribution.
    4. Update the album handler to return CloudFront URLs instead of presigned S3 URLs
       once the CDN is in place.

This file intentionally contains no CDK constructs. It will be replaced with a
real CloudFront construct when the domain and certificate are configured.
"""

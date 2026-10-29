# IP TLS deployment

These files document this server's IP-specific nginx and systemd configuration.
They use the existing port 80 web root and an isolated Certbot installation at
`/home/ubuntu/vocab-certbot`. The HTTPS default virtual host proxies `/vocab/`
to the application and other IP requests to the existing HTTP site. Existing
named virtual hosts continue to match their SNI names.

The IP certificate requires Certbot 5.4 or newer, Let's Encrypt's `shortlived`
profile, and public HTTP-01 access on port 80. Its validity is approximately
160 hours. The timer checks four times daily; the deploy hook tests the nginx
configuration before reloading. Monitor both the timer and the certificate's
expiry; a timer alone does not alert an administrator when renewal fails.

Check the current deployment and practice renewal:

```sh
sudo systemctl status vocab-ip-cert-renew.timer
sudo openssl x509 -in /home/ubuntu/vocab-certbot-production/config/live/175.27.210.206/cert.pem -noout -dates -ext subjectAltName
sudo /home/ubuntu/vocab-certbot/bin/certbot renew --dry-run --run-deploy-hooks \
  --deploy-hook /usr/local/sbin/vocab-cert-reload --non-interactive \
  --config-dir /home/ubuntu/vocab-certbot-production/config \
  --work-dir /home/ubuntu/vocab-certbot-production/work \
  --logs-dir /home/ubuntu/vocab-certbot-production/logs
```

The production app uses HTTPS only. The old HTTP endpoint remains available for
existing clients; browser data is origin-specific, so do not redirect users
before they synchronize or export their local data. Never copy private keys into
this repository.

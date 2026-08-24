# Security Review

Security is **non-negotiable** and must never regress. Apply when writing or reviewing
code that touches auth, user input, DB queries, API endpoints, file ops, crypto, or secrets.

## Contents
- How to apply
- Dangerous patterns to grep for
- Severity classification
- Final checklist
- Detailed checklist (authn, authz, input validation, injection, data protection, secrets, logging, API)
- OWASP Top 10
- Vulnerability patterns + secure alternatives
- Framework notes

## How to apply

1. **Identify sensitive areas** in the change: authn/authz, user input, DB queries, API
   endpoints, file ops, crypto, secrets/credentials.
2. **Grep for dangerous patterns** (below).
3. **Verify data protection**: encrypted at rest/in transit; no secrets in source; no
   sensitive data in logs; PII handled per regulation; keys rotatable/per-environment.
4. **Validate each finding**: check for mitigations elsewhere (middleware, framework
   auto-escaping, ORM), verify the input source (trusted vs untrusted), then classify.

## Dangerous patterns to grep for

```
eval(user_input)           # Code injection
exec(user_input)           # Code injection
os.system(user_input)      # Command injection
f"SELECT * FROM {table}"   # SQL injection
innerHTML = userData       # XSS
password = "hardcoded"     # Hardcoded secret
verify=False               # SSL verification disabled
shell=True                 # Shell injection risk
pickle.loads(              # Unsafe deserialization
yaml.load(                 # Unsafe YAML loading
```

## Severity classification

- **Critical**: remote code execution, authentication bypass, data breach
- **High**: SQL injection, XSS, privilege escalation
- **Medium**: missing rate limiting, verbose error messages, weak encryption
- **Low**: informational, minor configuration issues

## Final checklist

- [ ] No injection vulnerabilities (SQL, XSS, command, path, template)
- [ ] Authentication and authorization properly implemented
- [ ] All user input validated server-side
- [ ] Secrets not hardcoded
- [ ] Sensitive data encrypted
- [ ] Security events logged (without sensitive data)
- [ ] Rate limiting on public endpoints
- [ ] CORS configured correctly
- [ ] Dependencies free of known vulnerabilities

## Detailed checklist

### Authentication
Required for sensitive endpoints; strong password rules; passwords hashed (bcrypt/argon2);
cryptographically-random session tokens; expiration; logout invalidates session; MFA for
high-privilege ops; lockout after failed attempts.

### Authorization
Checked before data access; RBAC/ABAC; least privilege; ownership verified; admin functions
protected; no IDOR; consistent across API endpoints.

### Input Validation
All input validated; length limits; type/format validated; whitelist over blacklist;
server-side (not just client); file upload validation (type/size/content); URL/redirect
validation (prevent open redirects).

### Injection Prevention
- SQL: parameterized queries/prepared statements; ORM used correctly; no string concat.
- XSS: output encoding/escaping; CSP headers; no innerHTML with user data; template auto-escape.
- Command: no shell with user input; else strict whitelist; subprocess with list args, not `shell=True`.
- Other: LDAP, XXE, SSTI prevention.

### Data Protection
Encrypted at rest and in transit (TLS); PII per regulation; data minimization; secure
deletion when required; backups also encrypted.

### Secrets Management
No hardcoded credentials; no secrets in source; env vars or vault; keys rotatable; different
per environment; `.gitignore` covers secret files (`.env`, `credentials.json`).

### Logging and Monitoring
Security events logged; no sensitive data in logs; failed auth logged; tamper-resistant;
alerting on suspicious activity; audit trail for privileged ops.

### API Security
Rate limiting; CORS correct; versioning; proper HTTP methods; sensitive ops use
POST/PUT/DELETE; request size limits; token auth (not just cookies).

## OWASP Top 10

1. Broken Access Control — authorize every request
2. Cryptographic Failures — strong modern crypto (AES-256, RSA-2048+)
3. Injection — parameterize queries, escape output
4. Insecure Design — threat-model, security by design
5. Security Misconfiguration — secure defaults
6. Vulnerable Components — patch dependencies
7. Authentication Failures — strong auth, MFA, session mgmt
8. Data Integrity Failures — verify signatures, trusted sources
9. Logging Failures — audit trail, monitoring
10. SSRF — validate URLs, restrict internal network access

## Vulnerability patterns + secure alternatives

```python
# Code injection
eval(user_input)                      -> ast.literal_eval(user_input)  # literals only
# Command injection
subprocess.call(f"ls {d}", shell=True) -> subprocess.run(["ls", d], check=True)
# SQL injection
cursor.execute(f"... id = {user_id}")  -> cursor.execute("... id = %s", (user_id,))
# Deserialization
pickle.loads(user_data)                -> json.loads(user_data)
yaml.load(user_data)                   -> yaml.safe_load(user_data)
```

```javascript
// XSS
element.innerHTML = userContent;       // -> element.textContent = userContent;
                                       //    or DOMPurify.sanitize(userContent)
```

Path traversal: after `os.path.join(BASE_DIR, name)`, `realpath` it and confirm it still
starts with `realpath(BASE_DIR)`.

| Insecure | Secure alternative |
|----------|-------------------|
| MD5/SHA1 for passwords | bcrypt/argon2 |
| `pickle.loads(user_data)` | JSON with validation |
| `eval()` / `exec()` | explicit parsing |
| string-concat SQL | parameterized queries |
| plaintext secrets | env vars / vault |
| `shell=True` | list args without shell |
| `verify=False` | proper certificate validation |
| `innerHTML` with user data | `textContent` / DOMPurify |
| `yaml.load()` | `yaml.safe_load()` |
| rolling your own crypto | established libraries |

## Framework notes

- **Django**: autoescape on by default; use the ORM, avoid raw SQL; keep CSRF middleware on.
- **Express/Node**: `helmet` for headers; `express-rate-limit`; `express-validator`.
- **Flask**: `Markup.escape()`; SQLAlchemy parameterized; `SESSION_COOKIE_SECURE=True` in prod.
- **React**: JSX auto-escapes — avoid `dangerouslySetInnerHTML`; validate props (PropTypes/TS); CSP headers.

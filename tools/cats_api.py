#!/usr/bin/env python3
"""Scriptable client for WTF-OpenCats.

OpenCATS 0.10.0 ships no REST API and no API tokens. What it does have is a
front controller (index.php?m=<module>&a=<action>) that the browser drives with
a session cookie and, on POST, a CSRF token. This client logs in the same way a
browser does and then posts the same forms, so anything reachable in the UI is
reachable from code.

Usage:
    export CATS_URL=https://careers.wtfgyms.com
    export CATS_USER=admin
    export CATS_PASS='...'

    ./tools/cats_api.py whoami
    ./tools/cats_api.py add-company "Acme Pvt Ltd" --city Gurugram --state Haryana
    ./tools/cats_api.py set-departments 2 "Sales" "Ops" "Tech"
    ./tools/cats_api.py list-companies
    ./tools/cats_api.py list-departments 2
"""

import argparse
import http.cookiejar
from html.parser import HTMLParser
import os
import re
import sys
import urllib.parse
import urllib.request


class CatsClient:
    def __init__(self, base, user, password):
        self.base = base.rstrip("/")
        self.user = user
        self.password = password
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar)
        )
        self.opener.addheaders = [("User-Agent", "cats_api.py")]

    # --- plumbing ---------------------------------------------------------

    def _url(self, module, action=None, **params):
        q = {"m": module}
        if action:
            q["a"] = action
        q.update({k: v for k, v in params.items() if v is not None})
        return f"{self.base}/index.php?" + urllib.parse.urlencode(q)

    def get(self, module, action=None, **params):
        with self.opener.open(self._url(module, action, **params)) as r:
            return r.read().decode("utf-8", "replace")

    def post(self, module, action, data, **params):
        """POST a form. The CSRF token is scraped from the matching GET page,
        because index.php rejects any POST whose token does not match the
        session."""
        body = urllib.parse.urlencode(data).encode()
        req = urllib.request.Request(self._url(module, action, **params), data=body)
        with self.opener.open(req) as r:
            return r.status, r.geturl(), r.read().decode("utf-8", "replace")

    @staticmethod
    def csrf(html):
        m = re.search(r'name="csrfToken"[^>]*value="([^"]*)"', html)
        return m.group(1) if m else ""

    # --- auth -------------------------------------------------------------

    def login(self):
        page = self.get("login")
        status, url, html = self.post(
            "login",
            "attemptLogin",
            {
                "username": self.user,
                "password": self.password,
                "csrfToken": self.csrf(page),
            },
        )
        if "Invalid Username" in html or "m=login" in url and "attemptLogin" not in url:
            raise SystemExit("login failed: check CATS_USER / CATS_PASS")
        return self

    def whoami(self):
        html = self.get("home")
        m = re.search(r"CATS Administrator &lt;([^&]+)&gt;|<admin>", html)
        who = re.search(r"\(([^)]+)\)\s*</?", html)
        return {
            "authenticated": "Logout" in html,
            "site": who.group(1) if who else "?",
        }

    # --- companies --------------------------------------------------------

    def add_company(self, name, city="", state="", url="", country="India", phone=""):
        page = self.get("companies", "add")
        status, landed, html = self.post(
            "companies",
            "add",
            {
                "name": name,
                "address": "",
                "city": city,
                "state": state,
                "zip": "",
                "country": country,
                "phone1": phone,
                "phone2": "",
                "faxNumber": "",
                "url": url,
                "keyTechnologies": "",
                "isHot": "",
                "notes": "",
                "departmentsCSV": "",
                "csrfToken": self.csrf(page),
            },
        )
        m = re.search(r"companyID=(\d+)", landed)
        return {
            "http": status,
            "companyID": int(m.group(1)) if m else None,
            "url": landed,
            "fatal": "Fatal error" in html,
        }

    def list_companies(self):
        html = self.get("companies", "listByView", maxResults="200")
        rows = re.findall(
            r'companyID=(\d+)[^>]*>\s*([^<]+?)\s*</a>', html
        )
        seen, out = set(), []
        for cid, nm in rows:
            if cid not in seen:
                seen.add(cid)
                out.append({"companyID": int(cid), "name": nm.strip()})
        return out

    # --- departments ------------------------------------------------------

    def list_departments(self, company_id):
        """Read the company's departments.

        Taken from the edit form's departments <select>, where each department
        is one <option value="NAME">. The show page renders them as a
        <br />-separated blob in a table cell, which is far messier to parse
        reliably. Two control options are filtered out: "num" (the "N
        Departments" summary row) and "nullline" (the separator)."""
        html = self.get("companies", "edit", companyID=company_id)
        m = re.search(
            r'<select[^>]*name="departmentsSelect".*?</select>', html, re.S
        )
        if not m:
            return []
        out = []
        for value in re.findall(r'<option value="([^"]*)"', m.group(0)):
            if value in ("num", "nullline", "edit", "editdepartments", ""):
                continue
            out.append(value)
        return out

    def set_departments(self, company_id, names):
        """Replace the company's department list.

        There is no departments-only endpoint. Departments are a field on the
        company edit form, and onEdit() rewrites every other column from the
        same POST -- so posting just departmentsCSV would blank the address,
        phone, owner and so on. This therefore GETs the real edit form, keeps
        every existing field value, overrides only departmentsCSV, and posts
        the whole thing back."""
        form_page = self.get("companies", "edit", companyID=company_id)
        fields = parse_form(form_page, must_contain="departmentsCSV")
        fields["departmentsCSV"] = ",".join(names)
        fields["companyID"] = str(company_id)
        fields["csrfToken"] = self.csrf(form_page)
        status, landed, html = self.post(
            "companies", "edit", fields, companyID=company_id
        )
        return {
            "http": status,
            "url": landed,
            "fatal": "Fatal error" in html,
            "missing_fields": "Required fields are missing" in html,
        }


    # --- generic form submit ----------------------------------------------

    ERROR_RE = re.compile(
        r"(Invalid [a-z ]+\.|Required fields are missing\.|"
        r"Failed to (?:add|update) [a-z ]+\.)", re.I
    )

    def submit_form(self, module, action, marker, overrides,
                    get_params=None, post_params=None):
        """Round-trip a form: GET it, keep every existing value, apply
        overrides, POST it back. OpenCATS handlers rewrite every column from
        the POST, so a partial body silently blanks whatever it omits."""
        get_params = get_params or {}
        post_params = post_params or {}
        page = self.get(module, action, **get_params)
        fields = parse_form(page, must_contain=marker)
        if not fields:
            raise SystemExit(f"could not find a form containing {marker!r} "
                             f"on {module}:{action}")
        fields.update({k: str(v) for k, v in overrides.items()})
        fields["csrfToken"] = self.csrf(page)
        status, landed, html = self.post(module, action, fields, **post_params)
        err = self.ERROR_RE.search(html)
        return {
            "http": status,
            "url": landed,
            "fatal": "Fatal error" in html,
            "error": err.group(0) if err else None,
        }

    def edit_company(self, company_id, **overrides):
        overrides["companyID"] = company_id
        return self.submit_form(
            "companies", "edit", "departmentsCSV", overrides,
            get_params={"companyID": company_id},
        )

    # --- job orders --------------------------------------------------------

    def add_joborder(self, company_id, title, city, state, department="",
                     description="", openings=1, jobtype="H", public=True,
                     country="IN", salary="", notes=""):
        """Create a job order. public=True plus an Active status is what makes
        it appear on the public career portal."""
        return self.submit_form(
            "joborders", "add", "title",
            {
                "companyID": company_id,
                "title": title,
                "city": city,
                "state": state,
                "country": country,
                "department": department,
                "description": description,
                "notes": notes,
                "openings": openings,
                "type": jobtype,
                "salary": salary,
                "public": "on" if public else "",
            },
        )

    def list_joborders(self):
        html = self.get("joborders", "listByView", maxResults="200")
        rows = re.findall(r'jobOrderID=(\d+)[^>]*>\s*([^<]+?)\s*</a>', html)
        seen, out = set(), []
        for jid, title in rows:
            if jid not in seen:
                seen.add(jid)
                out.append({"jobOrderID": int(jid), "title": title.strip()})
        return out


class FormParser(HTMLParser):
    """Collect current values of every successful control, grouped per <form>.

    Grouping matters. An OpenCATS page carries several forms -- the header
    quick-search form is on every page and posts m=home&a=quickSearch. Scraping
    the page as one flat bag of fields puts those into the body, and because
    PHP merges POST over GET in $_REQUEST they override the m/a in the query
    string, so the request silently routes to the wrong module instead of the
    one being edited."""

    SKIP_TYPES = {"submit", "button", "reset", "image", "file"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self._cur = None
        self._select = None
        self._select_explicit = False
        self._select_first = None
        self._option_attrs = None
        self._textarea = None

    def _put(self, name, value):
        if self._cur is not None and name:
            self._cur[name] = value

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self._cur = {}
        elif tag == "input":
            name = a.get("name")
            if not name:
                return
            itype = (a.get("type") or "text").lower()
            if itype in self.SKIP_TYPES:
                return
            if itype in ("checkbox", "radio"):
                if "checked" in a:
                    self._put(name, a.get("value", "on"))
                elif itype == "checkbox" and self._cur is not None:
                    self._cur.setdefault(name, "")
            else:
                self._put(name, a.get("value", ""))
        elif tag == "select":
            self._select = a.get("name")
            self._select_explicit = False
            self._select_first = None
            if self._select and self._cur is not None:
                self._cur.setdefault(self._select, "")
        elif tag == "option" and self._select:
            self._option_attrs = a
            if self._select_first is None and "value" in a:
                self._select_first = a["value"]
            if "selected" in a and "value" in a:
                self._put(self._select, a["value"])
                self._select_explicit = True
        elif tag == "textarea":
            self._textarea = a.get("name")
            if self._textarea:
                self._put(self._textarea, "")

    def handle_data(self, data):
        if self._textarea and self._cur is not None:
            self._cur[self._textarea] = self._cur.get(self._textarea, "") + data
        elif self._option_attrs is not None and self._select:
            if self._select_first is None and "value" not in self._option_attrs:
                self._select_first = data.strip()
            if "selected" in self._option_attrs and "value" not in self._option_attrs:
                self._put(self._select, data.strip())
                self._select_explicit = True

    def handle_endtag(self, tag):
        if tag == "form":
            if self._cur:
                self.forms.append(self._cur)
            self._cur = None
        elif tag == "select":
            # A <select> with no option marked selected submits its FIRST
            # option, not an empty string. Getting this wrong made OpenCATS
            # reject the whole edit with "Invalid billing contact ID.", because
            # that field accepts -1 or digits but never "".
            if (self._select and not self._select_explicit
                    and self._select_first is not None and self._cur is not None):
                self._cur[self._select] = self._select_first
            self._select = None
            self._select_explicit = False
            self._select_first = None
        elif tag == "option":
            self._option_attrs = None
        elif tag == "textarea":
            self._textarea = None

    def close(self):
        super().close()
        if self._cur:
            self.forms.append(self._cur)
            self._cur = None


def parse_form(html, must_contain=None):
    """Return the fields of the form containing `must_contain`, minus the
    routing keys. m/a always come from the URL, never the body."""
    p = FormParser()
    p.feed(html)
    p.close()
    candidates = p.forms
    if must_contain:
        candidates = [f for f in p.forms if must_contain in f] or p.forms
    fields = dict(candidates[0]) if candidates else {}
    for routing_key in ("m", "a"):
        fields.pop(routing_key, None)
    return fields


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("whoami")
    sub.add_parser("list-companies")

    p = sub.add_parser("add-company")
    p.add_argument("name")
    p.add_argument("--city", default="")
    p.add_argument("--state", default="")
    p.add_argument("--url", default="")
    p.add_argument("--country", default="India")

    p = sub.add_parser("set-departments")
    p.add_argument("company_id", type=int)
    p.add_argument("names", nargs="+")

    p = sub.add_parser("list-departments")
    p.add_argument("company_id", type=int)

    p = sub.add_parser("edit-company")
    p.add_argument("company_id", type=int)
    p.add_argument("--city")
    p.add_argument("--state")
    p.add_argument("--address")
    p.add_argument("--zip")
    p.add_argument("--phone1")

    p = sub.add_parser("add-joborder")
    p.add_argument("company_id", type=int)
    p.add_argument("title")
    p.add_argument("--city", required=True)
    p.add_argument("--state", default="")
    p.add_argument("--department", default="")
    p.add_argument("--description", default="")
    p.add_argument("--openings", type=int, default=1)
    p.add_argument("--type", dest="jobtype", default="H")
    p.add_argument("--salary", default="")
    p.add_argument("--private", action="store_true")

    sub.add_parser("list-joborders")

    args = ap.parse_args()

    base = os.environ.get("CATS_URL")
    user = os.environ.get("CATS_USER")
    pw = os.environ.get("CATS_PASS")
    if not all([base, user, pw]):
        raise SystemExit("set CATS_URL, CATS_USER and CATS_PASS")

    c = CatsClient(base, user, pw).login()

    if args.cmd == "whoami":
        print(c.whoami())
    elif args.cmd == "add-company":
        print(c.add_company(args.name, args.city, args.state, args.url, args.country))
    elif args.cmd == "list-companies":
        for row in c.list_companies():
            print(f"{row['companyID']:>4}  {row['name']}")
    elif args.cmd == "set-departments":
        print(c.set_departments(args.company_id, args.names))
    elif args.cmd == "list-departments":
        for d in c.list_departments(args.company_id):
            print(d)
    elif args.cmd == "edit-company":
        ov = {k: v for k, v in vars(args).items()
              if k in ("city", "state", "address", "zip", "phone1") and v is not None}
        print(c.edit_company(args.company_id, **ov))
    elif args.cmd == "add-joborder":
        print(c.add_joborder(
            args.company_id, args.title, args.city, args.state,
            department=args.department, description=args.description,
            openings=args.openings, jobtype=args.jobtype,
            salary=args.salary, public=not args.private))
    elif args.cmd == "list-joborders":
        for row in c.list_joborders():
            print(f"{row['jobOrderID']:>4}  {row['title']}")


if __name__ == "__main__":
    main()

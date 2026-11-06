"""MkDocs hooks for the documentation site built from `docs/`.

`docs/` is written to read on GitHub as it is, and the site is built from the same files
unchanged. Three things GitHub gets right on its own, or that the folder layout cannot
say, are done here:

  * A relative link that leaves `docs/` -- `../GEMINI.md`, `../../bin/themes/README.md`
    -- resolves on GitHub because GitHub serves the whole tree. The site holds `docs/`
    only, so such a link is rewritten to the file on GitHub instead of being left broken.
    The same goes for a page the site leaves out, `_template.md`; that one is not broken
    on the site, only absent from it. A link to a page inside `docs/` that does not exist
    is left as it is, so the strict build reports it rather than pointing it at GitHub.
  * The page files under `docs/pages/` are laid out like the page sources, which is not
    how the tool shows them. Their part of the navigation is built from the menu
    definition instead (`src/rfsuite/app/manifest.lua`, read by `menu_structure.py`):
    one section per menu, titled and ordered as on the radio, under a top-level *Menu*
    whose overview is `docs/pages/README.md`, and each page listed under the label of its
    tile. What the tool fills in at run time is named in `RUNTIME_MENUS`. A page file no
    menu entry opens goes at the
    end of the menu that holds its folder, so nothing drops out of the navigation; a menu
    whose pages are all still unwritten is left out. A menu definition that cannot be
    read stops the build rather than falling back to the folder order.
  * Every other section follows `sidebar_position` in the front matter rather than the
    alphabetical order of the file names. Entries without one keep their alphabetical
    order after the ones that have it, and a section's `README.md` stays first.

Wired in by `hooks:` in `mkdocs.yml`; there is nothing to run by hand.
"""

import importlib.util
import posixpath
import re
import sys
from pathlib import Path

from mkdocs.structure.nav import Section
from mkdocs.structure.pages import Page

LINK = re.compile(r"(\]\()([^)\s]+)(\))")
POSITION = re.compile(r"^sidebar_position:[ \t]*([0-9]+)[ \t]*$", re.MULTILINE)

MENU_TITLE = "Menu"
MENU_DIR = "pages/"
MENU_INDEX = MENU_DIR + "README.md"

# What the menu definition cannot say, because the tool decides it at run time.
# `app/lib/dashboard_builder.lua` fills the Dashboard Settings grid: Per-Model Settings
# first, then one tile per theme, each opening the theme settings page.
RUNTIME_MENUS = {
    "settings_dashboard_settings_menu": ["settings/dashboard/overrides", "settings/dashboard/settings"],
}
# A page documented under another file name than its folder.
PAGE_FILES = {}


def _github_url(config, path, anchor):
    kind = "tree" if path.endswith("/") else "blob"
    return f"{config['repo_url'].rstrip('/')}/{kind}/master/{path}{anchor}"


def on_page_markdown(markdown, page, config, files):
    page_dir = posixpath.dirname(page.file.src_uri)

    def rewrite(match):
        target = match.group(2)
        if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.IGNORECASE) or target.startswith(("#", "/")):
            return match.group(0)
        path, _, anchor = target.partition("#")
        resolved = posixpath.normpath(posixpath.join("docs", page_dir, path))
        if resolved == "docs" or resolved.startswith("docs/"):
            inside = files.get_file_from_path(resolved[len("docs/"):]) if resolved != "docs" else None
            if inside is None or not inside.inclusion.is_excluded():
                return match.group(0)
        if path.endswith("/"):
            resolved += "/"
        return match.group(1) + _github_url(config, resolved, f"#{anchor}" if anchor else "") + match.group(3)

    return LINK.sub(rewrite, markdown)


def _position(item):
    page = item if isinstance(item, Page) else None
    if page is None:
        return None
    try:
        with open(page.file.abs_src_path, encoding="utf-8") as handle:
            head = handle.read(1024)
    except OSError:
        return None
    if not head.startswith("---"):
        return None
    match = POSITION.search(head.split("\n---", 1)[0])
    return int(match.group(1)) if match else None


def _sort(items):
    def key(indexed):
        index, item = indexed
        if isinstance(item, Page) and item.file.name in ("README", "index"):
            return (0, 0, index)
        position = _position(item)
        return (1, position, index) if position is not None else (2, 0, index)

    items[:] = [item for _, item in sorted(enumerate(items), key=key)]
    for item in items:
        if isinstance(item, Section):
            _sort(item.children)


def _pages(items):
    for item in items:
        if isinstance(item, Page):
            yield item
        elif isinstance(item, Section):
            yield from _pages(item.children)


def _menu_tree(config):
    path = Path(__file__).with_name("menu_structure.py")
    spec = importlib.util.spec_from_file_location("menu_structure", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["menu_structure"] = module
    spec.loader.exec_module(module)
    try:
        return module.menu_tree(Path(config["config_file_path"]).resolve().parent)
    except module.SourceError as err:
        raise RuntimeError(f"the menu navigation cannot be built: {err}") from None


def _section(title, children):
    section = Section(title, children)
    for child in children:
        child.parent = section
    return section


def _menu_section(old, config):
    """The `docs/pages/` section rebuilt in the order and with the titles of the menus."""
    files = {page.file.src_uri: page for page in _pages(old.children)}
    index = files.pop(MENU_INDEX, None)
    folders = []

    def build(node):
        """(nav item or None, the page folder the entry stands for)."""
        if not node["children"] and node["menuId"] in RUNTIME_MENUS:
            node = dict(node, children=[{"title": None, "menuId": None, "page": page, "children": []}
                                        for page in RUNTIME_MENUS[node["menuId"]]])
        built = [build(child) for child in node["children"]]
        page_file = PAGE_FILES.get(node["page"], node["page"])
        own = files.pop(f"{MENU_DIR}{page_file}.md", None) if node["page"] else None
        if own and node["title"] and not node["children"]:
            # The label of the tile, as the menu shows it; the page keeps its own heading.
            own.title = node["title"]
        if not node["children"]:
            return own, posixpath.dirname(node["page"]) if node["page"] else None
        folder = posixpath.commonpath([f for _, f in built if f is not None] or [""])
        children = ([own] if own else []) + [item for item, _ in built if item is not None]
        if not children:
            return None, folder
        section = _section(node["title"], children)
        if folder:
            folders.append((folder, section))
        return section, folder

    menu = _section(MENU_TITLE, ([index] if index else [])
                    + [item for item, _ in map(build, _menu_tree(config)) if item is not None])
    for path, page in files.items():
        folder = posixpath.dirname(path[len(MENU_DIR):-len(".md")])
        holders = [(f, s) for f, s in folders if folder == f or folder.startswith(f + "/")]
        holder = max(holders, key=lambda fs: len(fs[0]))[1] if holders else menu
        holder.children.append(page)
        page.parent = holder

    before, after = set(map(id, _pages(old.children))), set(map(id, _pages(menu.children)))
    if before != after:
        raise RuntimeError(f"the menu navigation lost or invented {len(before ^ after)} page(s)")
    return menu


def on_nav(nav, config, files):
    menu = None
    for position, item in enumerate(nav.items):
        if isinstance(item, Section) and any(p.file.src_uri == MENU_INDEX for p in item.children
                                             if isinstance(p, Page)):
            menu = _menu_section(item, config)
            del nav.items[position]
            break
    _sort(nav.items)
    if menu is not None:
        menu.parent = None
        nav.items.insert(1, menu)
    # The previous/next links at the foot of a page were set in the unsorted order.
    nav.pages = list(_pages(nav.items))
    for before, after in zip([None] + nav.pages, nav.pages + [None]):
        if before is not None:
            before.next_page = after
        if after is not None:
            after.previous_page = before
    return nav

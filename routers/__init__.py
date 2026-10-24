"""Route modules. Each exposes ``build_router(core)``; ``core`` is the main module, passed in by main.py.

Routers never ``import main``: running ``python main.py`` loads that file twice (as ``__main__`` and again
as ``main`` when uvicorn imports ``main:app``), so importing it here would create a second app and state.
"""

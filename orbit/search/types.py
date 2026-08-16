from __future__ import annotations
from dataclasses import dataclass

@dataclass
class Hit:
    atom_id: int
    event_id: int
    atom_uri: str           # orbit://atom/<id>
    event_uri: str          # orbit://event/<id>
    app_bundle_id: str
    app_name: str
    window_title: str | None
    timestamp: str
    role: str
    label: str | None
    snippet_html: str
    score: float
    # score: lower=better for lexical/semantic; higher=better for hybrid (RRF).

    @classmethod
    def from_row(cls, row, *, mode: str = "lexical") -> "Hit":
        from orbit.storage.links import atom_uri, event_uri
        return cls(
            atom_id=row["atom_id"],
            event_id=row["event_id"],
            atom_uri=atom_uri(row["atom_id"]),
            event_uri=event_uri(row["event_id"]),
            app_bundle_id=row["app_bundle_id"],
            app_name=row["app_name"],
            window_title=row["window_title"],
            timestamp=row["timestamp"],
            role=row["role"],
            label=row["label"],
            snippet_html=row["snippet_html"],
            score=row["score"],
        )

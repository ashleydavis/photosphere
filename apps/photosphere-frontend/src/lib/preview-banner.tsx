import React, { useEffect } from "react";
import { openBugReport } from "user-interface";
import "./preview-banner.css";

//
// The class the banner puts on the body while it is shown, so the layout offsets in preview-banner.css apply only
// when the banner is there.
//
const BANNER_BODY_CLASS = "has-preview-banner";

//
// Banner pinned to the top of the desktop app telling the user this is a preview
// release and giving them a link to report issues on GitHub.
//
export function PreviewBanner() {
    useEffect(() => {
        document.body.classList.add(BANNER_BODY_CLASS);
        return () => {
            document.body.classList.remove(BANNER_BODY_CLASS);
        };
    }, []);

    return (
        <div id="preview-banner" className="fixed top-0 inset-x-0 z-[600] flex h-8 items-center justify-center gap-2.5 bg-amber-900 text-[13px] text-amber-100">
            <span>
                This is a preview release. Please report UX problems and bugs.
            </span>
            <button
                data-id="report-issue-button"
                className="cursor-pointer font-semibold underline"
                onClick={() => openBugReport()}
                >
                Report an issue
            </button>
        </div>
    );
}

import type { IStory } from "./types";

import { stories as aboutPageStories } from "./pages/about.stories";
import { stories as configurationPageStories } from "./pages/configuration.stories";
import { stories as databasesPageStories } from "./pages/databases.stories";
import { stories as databaseSummaryPageStories } from "./pages/database-summary.stories";
import { stories as galleryPageStories } from "./pages/gallery.stories";
import { stories as importPageStories } from "./pages/import.stories";
import { stories as mapPageStories } from "./pages/map.stories";
import { stories as newsPageStories } from "./pages/news.stories";
import { stories as secretsPageStories } from "./pages/secrets.stories";

import { stories as addDatabaseModalStories } from "./modals/add-database-modal.stories";
import { stories as clusterModalStories } from "./modals/cluster-modal.stories";
import { stories as configureSecretsModalStories } from "./modals/configure-secrets-modal.stories";
import { stories as createDatabaseModalStories } from "./modals/create-database-modal.stories";
import { stories as editDatabaseModalStories } from "./modals/edit-database-modal.stories";
import { stories as openDatabaseModalStories } from "./modals/open-database-modal.stories";
import { stories as s3BrowserModalStories } from "./modals/s3-browser-modal.stories";
import { stories as selectSecretModalStories } from "./modals/select-secret-modal.stories";

import { stories as configurationDialogStories } from "./dialogs/configuration-dialog.stories";
import { stories as createSecretDialogStories } from "./dialogs/create-secret-dialog.stories";
import { stories as deleteConfirmationDialogStories } from "./dialogs/delete-confirmation-dialog.stories";
import { stories as receiveDatabaseDialogStories } from "./dialogs/receive-database-dialog.stories";
import { stories as receiveSecretDialogStories } from "./dialogs/receive-secret-dialog.stories";
import { stories as removeDatabaseDialogStories } from "./dialogs/remove-database-dialog.stories";
import { stories as replicateDatabaseDialogStories } from "./dialogs/replicate-database-dialog.stories";
import { stories as setLocationDialogStories } from "./dialogs/set-location-dialog.stories";
import { stories as setPhotoDateDialogStories } from "./dialogs/set-photo-date-dialog.stories";
import { stories as shareDatabaseDialogStories } from "./dialogs/share-database-dialog.stories";
import { stories as shareSecretDialogStories } from "./dialogs/share-secret-dialog.stories";
import { stories as viewDatabaseDialogStories } from "./dialogs/view-database-dialog.stories";
import { stories as viewSecretDialogStories } from "./dialogs/view-secret-dialog.stories";

import { stories as assetInfoStories } from "./components/asset-info.stories";
import { stories as assetViewStories } from "./components/asset-view.stories";
import { stories as carouselStories } from "./components/carousel.stories";
import { stories as collapsibleSectionStories } from "./components/collapsible-section.stories";
import { stories as emptyDatabaseStories } from "./components/empty-database.stories";
import { stories as filmStripStories } from "./components/film-strip.stories";
import { stories as fpsStories } from "./components/fps.stories";
import { stories as fullImageStories } from "./components/full-image.stories";
import { stories as fullScreenSpinnerStories } from "./components/full-screen-spinner.stories";
import { stories as galleryStories } from "./components/gallery.stories";
import { stories as galleryImageStories } from "./components/gallery-image.stories";
import { stories as galleryLayoutStories } from "./components/gallery-layout.stories";
import { stories as galleryPreviewStories } from "./components/gallery-preview.stories";
import { stories as galleryScrollbarStories } from "./components/gallery-scrollbar.stories";
import { stories as leftSidebarStories } from "./components/left-sidebar.stories";
import { stories as mapViewStories } from "./components/map-view.stories";
import { stories as navbarStories } from "./components/navbar.stories";
import { stories as noDatabaseLoadedStories } from "./components/no-database-loaded.stories";
import { stories as rightSidebarStories } from "./components/right-sidebar.stories";
import { stories as spinnerStories } from "./components/spinner.stories";
import { stories as toastContainerStories } from "./components/toast-container.stories";
import { stories as videoStories } from "./components/video.stories";

//
// Flat list of every registered story.
// Stories appear in the browser in this order: Pages, Modals, Dialogs, Components.
// Within each category entries follow the import order above (alphabetical by file name).
//
export const stories: IStory[] = [
    ...aboutPageStories,
    ...configurationPageStories,
    ...databasesPageStories,
    ...databaseSummaryPageStories,
    ...galleryPageStories,
    ...importPageStories,
    ...mapPageStories,
    ...newsPageStories,
    ...secretsPageStories,

    ...addDatabaseModalStories,
    ...clusterModalStories,
    ...configureSecretsModalStories,
    ...createDatabaseModalStories,
    ...editDatabaseModalStories,
    ...openDatabaseModalStories,
    ...s3BrowserModalStories,
    ...selectSecretModalStories,

    ...configurationDialogStories,
    ...createSecretDialogStories,
    ...deleteConfirmationDialogStories,
    ...receiveDatabaseDialogStories,
    ...receiveSecretDialogStories,
    ...removeDatabaseDialogStories,
    ...replicateDatabaseDialogStories,
    ...setLocationDialogStories,
    ...setPhotoDateDialogStories,
    ...shareDatabaseDialogStories,
    ...shareSecretDialogStories,
    ...viewDatabaseDialogStories,
    ...viewSecretDialogStories,

    ...assetInfoStories,
    ...assetViewStories,
    ...carouselStories,
    ...collapsibleSectionStories,
    ...emptyDatabaseStories,
    ...filmStripStories,
    ...fpsStories,
    ...fullImageStories,
    ...fullScreenSpinnerStories,
    ...galleryStories,
    ...galleryImageStories,
    ...galleryLayoutStories,
    ...galleryPreviewStories,
    ...galleryScrollbarStories,
    ...leftSidebarStories,
    ...mapViewStories,
    ...navbarStories,
    ...noDatabaseLoadedStories,
    ...rightSidebarStories,
    ...spinnerStories,
    ...toastContainerStories,
    ...videoStories,
];

export type { IStory, StoryCategory } from "./types";

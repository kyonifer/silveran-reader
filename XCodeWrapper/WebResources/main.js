import FoliateManager from "./FoliateManager.js";
import BookLoader from "./BookLoader.js";
import { debugLog } from "./DebugConfig.js";

debugLog("Main", "Initializing FoliateManager");

window.foliateManager = new FoliateManager();
window.bookLoader = new BookLoader(window.foliateManager);

debugLog("Main", "Initialization complete");

/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class LibraryWindow : AppWindow {
    public const int SIDEBAR_MIN_WIDTH = 200;
    public const int SIDEBAR_MAX_WIDTH = 320;
    public const int PAGE_MIN_WIDTH = 
        Thumbnail.MAX_SCALE + (CheckerboardLayout.COLUMN_GUTTER_PADDING * 2);
    
    public const int SORT_EVENTS_ORDER_ASCENDING = 0;
    public const int SORT_EVENTS_ORDER_DESCENDING = 1;
    
    private const string[] SUPPORTED_MOUNT_SCHEMES = {
        "gphoto2:",
        "disk:",
        "file:"
    };
    
    // these values reflect the priority various background operations have when reporting
    // progress to the LibraryWindow progress bar ... higher values give priority to those reports
    private const int REALTIME_UPDATE_PROGRESS_PRIORITY =   40;
    private const int REALTIME_IMPORT_PROGRESS_PRIORITY =   50;
    private const int METADATA_WRITER_PROGRESS_PRIORITY =   30;
    private const int MIMIC_MANAGER_PROGRESS_PRIORITY =     20;
    
    protected enum TargetType {
        URI_LIST,
        MEDIA_LIST
    }
    
    public const Gtk.TargetEntry[] DEST_TARGET_ENTRIES = {
        { "text/uri-list", Gtk.TargetFlags.OTHER_APP, TargetType.URI_LIST },
        { "shotwell/media-id-atom", Gtk.TargetFlags.SAME_APP, TargetType.MEDIA_LIST }
    };
    
    // special Yorba-selected sidebar background color for standard themes (humanity,
    // clearlooks, etc.); dark themes use the theme's native background color
    public static Gdk.Color SIDEBAR_STANDARD_BG_COLOR = parse_color("#EEE");
    
    // Max brightness value to trigger SIDEBAR_STANDARD_BG_COLOR 
    public const uint16 STANDARD_COMPONENT_MINIMUM = 0xe000;
    
    // In fullscreen mode, want to use LibraryPhotoPage, but fullscreen has different requirements,
    // esp. regarding when the widget is realized and when it should first try and throw them image
    // on the page.  This handles this without introducing lots of special cases in
    // LibraryPhotoPage.
    private class FullscreenPhotoPage : LibraryPhotoPage {
        private CollectionPage collection;
        private Thumbnail start;
        
        public FullscreenPhotoPage(CollectionPage collection, Thumbnail start) {
            this.collection = collection;
            this.start = start;
        }
        
        public override void switched_to() {
            Photo? photo = start.get_media_source() as Photo;
            if (photo != null)
                display_for_collection(collection, photo);
            
            base.switched_to();
        }
    }
    
    private class PageLayout : Gtk.VBox {
        private string page_name;
        private Gtk.Toolbar toolbar;
        
        public PageLayout(Page page) {
            page_name = page.get_page_name();
            toolbar = page.get_toolbar();
            
            set_homogeneous(false);
            set_spacing(0);
            
            pack_start(page, true, true, 0);
            pack_end(toolbar, false, false, 0);
        }
        
        ~PageLayout() {
#if TRACE_DTORS
            debug("DTOR: PageLayout for %s", page_name);
#endif
        }
        
        public override void destroy() {
            // because Page destroys all its own widgets, need to prevent a double-destroy on
            // the toolbar
            if (toolbar is Gtk.Widget)
                remove(toolbar);
            toolbar = null;
            
            base.destroy();
        }
    }

    private string import_dir = Environment.get_home_dir();

    private Gtk.VPaned sidebar_paned = new Gtk.VPaned();
    private Gtk.HPaned client_paned = new Gtk.HPaned();
    private Gtk.Frame bottom_frame = new Gtk.Frame(null);
    
    private Gtk.AccelGroup? paused_accel_group = null;
    
    // Static (default) pages
    private LibraryPage library_page = null;
    private MasterEventsDirectoryPage.Stub events_directory_page = null;
    private LibraryPhotoPage photo_page = null;
    private TrashPage.Stub trash_page = null;
    private NoEventPage.Stub no_event_page = null;
    private OfflinePage.Stub offline_page = null;
    private LastImportPage.Stub last_import_page = null;
    private FlaggedPage.Stub flagged_page = null;
    private VideosPage.Stub videos_page = null;
    private ImportQueuePage import_queue_page = null;
    private bool displaying_import_queue_page = false;
    private OneShotScheduler properties_scheduler = null;
    private bool notify_library_is_home_dir = true;
    
    // Dynamically added/removed pages
    private Gee.HashMap<Page, PageLayout> page_layouts = new Gee.HashMap<Page, PageLayout>();
    private Gee.ArrayList<EventPage.Stub> event_list = new Gee.ArrayList<EventPage.Stub>();
    private Gee.ArrayList<SubEventsDirectoryPage.Stub> events_dir_list =
        new Gee.ArrayList<SubEventsDirectoryPage.Stub>();
    private Gee.HashMap<Tag, TagPage.Stub> tag_map = new Gee.HashMap<Tag, TagPage.Stub>();
#if !NO_CAMERA
    private Gee.HashMap<string, ImportPage> camera_pages = new Gee.HashMap<string, ImportPage>(
        str_hash, str_equal, direct_equal);

    // this is to keep track of cameras which initiate the app
    private static Gee.HashSet<string> initial_camera_uris = new Gee.HashSet<string>();
#endif

    private Sidebar sidebar = new Sidebar();
#if !NO_CAMERA
    private SidebarMarker cameras_marker = null;
#endif
    private SidebarMarker tags_marker = null;
    
    private Gtk.VBox top_section = new Gtk.VBox(false, 0);
    private Gtk.Frame background_progress_frame = new Gtk.Frame(null);
    private Gtk.ProgressBar background_progress_bar = new Gtk.ProgressBar();
    private bool background_progress_displayed = false;
    
    private BasicProperties basic_properties = new BasicProperties();
    private ExtendedPropertiesWindow extended_properties;
    
    private Gtk.Notebook notebook = new Gtk.Notebook();
    private Gtk.Box layout = new Gtk.VBox(false, 0);
    
    private bool events_sort_ascending = false;
    private int current_progress_priority = 0;
    
    public LibraryWindow(ProgressMonitor monitor) {
        // prepare the default parent and orphan pages
        // (these are never removed from the system)
        library_page = new LibraryPage(monitor);
        last_import_page = LastImportPage.create_stub();
        events_directory_page = MasterEventsDirectoryPage.create_stub();
        import_queue_page = new ImportQueuePage();
        import_queue_page.batch_removed.connect(import_queue_batch_finished);
        trash_page = TrashPage.create_stub();
        videos_page = VideosPage.create_stub();

        // create and connect extended properties window
        extended_properties = new ExtendedPropertiesWindow(this);
        extended_properties.hide.connect(hide_extended_properties);
        extended_properties.show.connect(show_extended_properties);

        // add the default parents and orphans to the notebook
        add_parent_page(library_page);
        sidebar.add_parent(videos_page);
        sidebar.add_parent(last_import_page);
        sidebar.add_parent(events_directory_page);
        sidebar.add_parent(trash_page);
        
        properties_scheduler = new OneShotScheduler("LibraryWindow properties",
            on_update_properties_now);
        
        // watch for new & removed events
        Event.global.items_added.connect(on_added_events);
        Event.global.items_removed.connect(on_removed_events);
        Event.global.items_altered.connect(on_events_altered);
        
        // watch for new & removed tags
        Tag.global.contents_altered.connect(on_tags_added_removed);
        Tag.global.items_altered.connect(on_tags_altered);
        
        // watch for photos and videos placed offline
        LibraryPhoto.global.offline_contents_altered.connect(on_offline_contents_altered);
        Video.global.offline_contents_altered.connect(on_offline_contents_altered);
        sync_offline_page_state();

        // watch for photos with no events
        Event.global.no_event_collection_altered.connect(on_no_event_collection_altered);
        enable_disable_no_event_page(Event.global.get_no_event_objects().size > 0);
        
        // start in the collection page
        sidebar.place_cursor(library_page);
        
        // monitor cursor changes to select proper page in notebook
        sidebar.cursor_changed.connect(on_sidebar_cursor_changed);
        
        create_layout(library_page);

        // settings that should persist between sessions
        load_configuration();

        // add stored events
        foreach (DataObject object in Event.global.get_all())
            add_event_page((Event) object);
        
        // if events exist, expand to first one
        if (Event.global.get_count() > 0)
            sidebar.expand_to_first_child(events_directory_page.get_marker());
        
        // add tags
        foreach (DataObject object in Tag.global.get_all())
            add_tag_page((Tag) object);
        
        // if tags exist, expand them
        if (tags_marker != null)
            sidebar.expand_branch(tags_marker);
        
        // set up main window as a drag-and-drop destination (rather than each page; assume
        // a drag and drop is for general library import, which means it goes to library_page)
        Gtk.drag_dest_set(this, Gtk.DestDefaults.ALL, DEST_TARGET_ENTRIES,
            Gdk.DragAction.COPY | Gdk.DragAction.LINK | Gdk.DragAction.ASK);
        
#if !NO_CAMERA
        // monitor the camera table for additions and removals
        CameraTable.get_instance().camera_added.connect(add_camera_page);
        CameraTable.get_instance().camera_removed.connect(remove_camera_page);
        
        // need to populate pages with what's known now by the camera table
        foreach (DiscoveredCamera camera in CameraTable.get_instance().get_cameras())
            add_camera_page(camera);
#endif
        
        // connect to sidebar signal used ommited on drag-and-drop orerations
        sidebar.drop_received.connect(drop_received);
        
        // monitor various states of the media source collections to update page availability
        foreach (MediaSourceCollection sources in MediaCollectionRegistry.get_instance().get_all()) {
            sources.trashcan_contents_altered.connect(on_trashcan_contents_altered);
            sources.import_roll_altered.connect(sync_last_import_visibility);
            sources.flagged_contents_altered.connect(sync_flagged_visibility);
            sources.items_altered.connect(on_media_altered);
        }
        
        sync_last_import_visibility();
        sync_flagged_visibility();
        
        Video.global.contents_altered.connect(sync_videos_visibility);
        sync_videos_visibility();
        
        MetadataWriter.get_instance().progress.connect(on_metadata_writer_progress);
        LibraryPhoto.library_monitor.auto_update_progress.connect(on_library_monitor_auto_update_progress);
        LibraryPhoto.library_monitor.auto_import_preparing.connect(on_library_monitor_auto_import_preparing);
        LibraryPhoto.library_monitor.auto_import_progress.connect(on_library_monitor_auto_import_progress);
        LibraryPhoto.mimic_manager.progress.connect(on_mimic_manager_progress);
    }
    
    ~LibraryWindow() {
        Event.global.items_added.disconnect(on_added_events);
        Event.global.items_removed.disconnect(on_removed_events);
        Event.global.items_altered.disconnect(on_events_altered);
        
        Tag.global.contents_altered.disconnect(on_tags_added_removed);
        Tag.global.items_altered.disconnect(on_tags_altered);
        
#if !NO_CAMERA
        CameraTable.get_instance().camera_added.disconnect(add_camera_page);
        CameraTable.get_instance().camera_removed.disconnect(remove_camera_page);
#endif
        
        unsubscribe_from_basic_information(get_current_page());

        extended_properties.hide.disconnect(hide_extended_properties);
        extended_properties.show.disconnect(show_extended_properties);
        
        LibraryPhoto.global.trashcan_contents_altered.disconnect(on_trashcan_contents_altered);
        Video.global.trashcan_contents_altered.disconnect(on_trashcan_contents_altered);
        
        foreach (MediaSourceCollection media_sources in MediaCollectionRegistry.get_instance().get_all())
            media_sources.items_altered.disconnect(on_media_altered);
        
        MetadataWriter.get_instance().progress.disconnect(on_metadata_writer_progress);
        LibraryPhoto.library_monitor.auto_update_progress.disconnect(on_library_monitor_auto_update_progress);
        LibraryPhoto.library_monitor.auto_import_preparing.disconnect(on_library_monitor_auto_import_preparing);
        LibraryPhoto.library_monitor.auto_import_progress.disconnect(on_library_monitor_auto_import_progress);
        LibraryPhoto.mimic_manager.progress.disconnect(on_mimic_manager_progress);
    }
    
    private Gtk.ActionEntry[] create_actions() {
        Gtk.ActionEntry[] actions = new Gtk.ActionEntry[0];
        
        Gtk.ActionEntry import = { "CommonFileImport", Resources.IMPORT,
            TRANSLATABLE, "<Ctrl>I", TRANSLATABLE, on_file_import };
        import.label = _("_Import From Folder...");
        import.tooltip = _("Import photos from disk to library");
        actions += import;
        
        // Add one action per alien database driver
        foreach (AlienDatabaseDriver driver in AlienDatabaseHandler.get_instance().get_drivers()) {
            Gtk.ActionEntry import_from_alien_db = driver.get_action_entry();
            actions += import_from_alien_db;
        }

        Gtk.ActionEntry sort = { "CommonSortEvents", null, TRANSLATABLE, null, null,
            on_sort_events };
        sort.label = _("Sort _Events");
        actions += sort;

        Gtk.ActionEntry preferences = { "CommonPreferences", Gtk.STOCK_PREFERENCES, TRANSLATABLE,
            null, TRANSLATABLE, on_preferences };
        preferences.label = Resources.PREFERENCES_MENU;
        preferences.tooltip = Resources.PREFERENCES_TOOLTIP;
        actions += preferences;
        
        Gtk.ActionEntry empty = { "CommonEmptyTrash", Gtk.STOCK_CLEAR, TRANSLATABLE, null, null,
            on_empty_trash };
        empty.label = _("Empty T_rash");
        empty.tooltip = _("Delete all photos in the trash");
        actions += empty;
        
        Gtk.ActionEntry jump_to_event = { "CommonJumpToEvent", null, TRANSLATABLE, null,
            TRANSLATABLE, on_jump_to_event };
        jump_to_event.label = _("View Eve_nt for Photo");
        jump_to_event.tooltip = _("Go to this photo's event");
        actions += jump_to_event;
        
        return actions;
    }
    
    private Gtk.ToggleActionEntry[] create_toggle_actions() {
        Gtk.ToggleActionEntry[] actions = new Gtk.ToggleActionEntry[0];

        Gtk.ToggleActionEntry basic_props = { "CommonDisplayBasicProperties", null,
            TRANSLATABLE, "<Ctrl><Shift>I", TRANSLATABLE, on_display_basic_properties, false };
        basic_props.label = _("_Basic Information");
        basic_props.tooltip = _("Display basic information for the selection");
        actions += basic_props;

        Gtk.ToggleActionEntry extended_props = { "CommonDisplayExtendedProperties", null,
            TRANSLATABLE, "<Ctrl><Shift>X", TRANSLATABLE, on_display_extended_properties, false };
        extended_props.label = _("E_xtended Information");
        extended_props.tooltip = _("Display extended information for the selection");
        actions += extended_props;

        return actions;
    }

    private Gtk.RadioActionEntry[] create_order_actions() {
        Gtk.RadioActionEntry[] actions = new Gtk.RadioActionEntry[0];

        Gtk.RadioActionEntry ascending = { "CommonSortEventsAscending",
            Gtk.STOCK_SORT_ASCENDING, TRANSLATABLE, null, TRANSLATABLE,
            SORT_EVENTS_ORDER_ASCENDING };
        ascending.label = _("_Ascending");
        ascending.tooltip = _("Sort photos in an ascending order");
        actions += ascending;

        Gtk.RadioActionEntry descending = { "CommonSortEventsDescending",
            Gtk.STOCK_SORT_DESCENDING, TRANSLATABLE, null, TRANSLATABLE,
            SORT_EVENTS_ORDER_DESCENDING };
        descending.label = _("D_escending");
        descending.tooltip = _("Sort photos in a descending order");
        actions += descending;

        return actions;
    }

    public override void show_all() {
        base.show_all();

        Gtk.ToggleAction basic_properties_action = 
            (Gtk.ToggleAction) get_current_page().common_action_group.get_action(
            "CommonDisplayBasicProperties");
        assert(basic_properties_action != null);

        if (!basic_properties_action.get_active()) {
            bottom_frame.hide();
        }
    }
    
    public static LibraryWindow get_app() {
        assert(instance is LibraryWindow);
        
        return (LibraryWindow) instance;
    }
    
    private int64 get_event_directory_page_time(SubEventsDirectoryPage.Stub *stub) {
        return (stub->get_year() * 100) + stub->get_month();
    }
    
    private int64 event_branch_comparator(void *aptr, void *bptr) {
        SidebarPage *a = (SidebarPage *) aptr;
        SidebarPage *b = (SidebarPage *) bptr;
        
        int64 start_a, start_b;
        if (a is SubEventsDirectoryPage.Stub && b is SubEventsDirectoryPage.Stub) {
            start_a = get_event_directory_page_time((SubEventsDirectoryPage.Stub *) a);
            start_b = get_event_directory_page_time((SubEventsDirectoryPage.Stub *) b);
        } else if (a is NoEventPage.Stub) {
            assert(b is SubEventsDirectoryPage.Stub || b is EventPage.Stub);
            return events_sort_ascending ? 1 : -1;
        } else if (b is NoEventPage.Stub) {
            assert(a is SubEventsDirectoryPage.Stub || a is EventPage.Stub);
            return events_sort_ascending ? -1 : 1;
        } else {
            assert(a is EventPage.Stub);
            assert(b is EventPage.Stub);
            
            start_a = ((EventPage.Stub *) a)->event.get_start_time();
            start_b = ((EventPage.Stub *) b)->event.get_start_time();
        }
        
        return start_a - start_b;
    }
    
    private int64 event_branch_ascending_comparator(void *a, void *b) {
        return event_branch_comparator(a, b);
    }
    
    private int64 event_branch_descending_comparator(void *a, void *b) {
        return event_branch_comparator(b, a);
    }
    
    private Comparator get_event_branch_comparator(int event_sort) {
        if (event_sort == LibraryWindow.SORT_EVENTS_ORDER_ASCENDING) {
            return event_branch_ascending_comparator;
        } else {
            assert(event_sort == LibraryWindow.SORT_EVENTS_ORDER_DESCENDING);
            
            return event_branch_descending_comparator;
        }
    }
    
    // This may be called before Debug.init(), so no error logging may be made
    public static bool is_mount_uri_supported(string uri) {
        foreach (string scheme in SUPPORTED_MOUNT_SCHEMES) {
            if (uri.has_prefix(scheme))
                return true;
        }
        
        return false;
    }
    
    public override void add_common_actions(Gtk.ActionGroup action_group) {
        base.add_common_actions(action_group);
        
        action_group.add_actions(create_actions(), this);
        action_group.add_toggle_actions(create_toggle_actions(), this);
        action_group.add_radio_actions(create_order_actions(),
            SORT_EVENTS_ORDER_ASCENDING, on_events_sort_changed);
    }
    
    public override string get_app_role() {
        return Resources.APP_LIBRARY_ROLE;
    }

    protected override void on_quit() {
        Config.get_instance().set_library_window_state(maximized, dimensions);

        Config.get_instance().set_sidebar_position(client_paned.position);

        Config.get_instance().set_photo_thumbnail_scale(MediaPage.get_global_thumbnail_scale());
        
        base.on_quit();
    }
    
    protected override void on_fullscreen() {
        CollectionPage collection = null;
        Thumbnail start = null;
        
        // This method indicates one of the shortcomings right now in our design: we need a generic
        // way to access the collection of items each page is responsible for displaying.  Once
        // that refactoring is done, this code should get much simpler.
        
        Page current_page = get_current_page();
        if (current_page is CollectionPage) {
            CheckerboardItem item = ((CollectionPage) current_page).get_fullscreen_photo();
            if (item == null) {
                message("No fullscreen photo for this view");
                
                return;
            }
            
            collection = (CollectionPage) current_page;
            start = (Thumbnail) item;
        } else if (current_page is EventsDirectoryPage) {
            collection = ((EventsDirectoryPage) current_page).get_fullscreen_event();
            start = (Thumbnail) collection.get_fullscreen_photo();
        } else if (current_page is LibraryPhotoPage) {
            collection = ((LibraryPhotoPage) current_page).get_controller_page();
            start =  (Thumbnail) collection.get_view().get_view_for_source(
                ((LibraryPhotoPage) current_page).get_photo());
        } else {
            message("Unable to present fullscreen view for this page");
            
            return;
        }
        
        if (collection == null || start == null)
            return;
        
        FullscreenPhotoPage fs_photo = new FullscreenPhotoPage(collection, start);

        go_fullscreen(fs_photo);
    }
    
    private void on_file_import() {
        Gtk.FileChooserDialog import_dialog = new Gtk.FileChooserDialog(_("Import From Folder"), null,
            Gtk.FileChooserAction.SELECT_FOLDER, Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, 
            Gtk.STOCK_OK, Gtk.ResponseType.OK);
        import_dialog.set_local_only(false);
        import_dialog.set_select_multiple(true);
        import_dialog.set_current_folder(import_dir);
        
        int response = import_dialog.run();
        
        if (response == Gtk.ResponseType.OK) {
            // force file linking if directory is inside current library directory
            Gtk.ResponseType copy_files_response =
                AppDirs.is_in_import_dir(File.new_for_uri(import_dialog.get_uri()))
                    ? Gtk.ResponseType.REJECT : copy_files_dialog();
            
            if (copy_files_response != Gtk.ResponseType.CANCEL) {
                dispatch_import_jobs(import_dialog.get_uris(), "folders", 
                    copy_files_response == Gtk.ResponseType.ACCEPT);
            }
        }
        
        import_dir = import_dialog.get_current_folder();
        import_dialog.destroy();
    }
    
    protected override void update_actions(int selected_count, int count) {
        set_common_action_sensitive("CommonEmptyTrash", can_empty_trash());
        set_common_action_sensitive("CommonJumpToEvent", can_jump_to_event());
        
        base.update_actions(selected_count, count);
    }
    
    private void on_trashcan_contents_altered() {
        set_common_action_sensitive("CommonEmptyTrash", can_empty_trash());
        sidebar.update_page_icon(trash_page);
    }
    
    private bool can_empty_trash() {
        return (LibraryPhoto.global.get_trashcan_count() > 0) || (Video.global.get_trashcan_count() > 0);
    }
    
    private void on_empty_trash() {
        Gee.ArrayList<MediaSource> to_remove = new Gee.ArrayList<MediaSource>();
        to_remove.add_all(LibraryPhoto.global.get_trashcan_contents());
        to_remove.add_all(Video.global.get_trashcan_contents());
        
        remove_from_app(to_remove, _("Empty Trash"),  _("Emptying Trash..."));
        
        AppWindow.get_command_manager().reset();
    }
    
    private bool can_jump_to_event() {
        ViewCollection view = get_current_page().get_view();
        
        if (view.get_selected_count() == 1) {
            DataSource selected_source = view.get_selected_source_at(0);
            if (selected_source is Event)
                return true;
            else if (selected_source is MediaSource)
                return ((MediaSource) view.get_selected_source_at(0)).get_event() != null;
            else
                return false;
        } else {
            return false;
        }
    }
    
    private void on_jump_to_event() {
        ViewCollection view = get_current_page().get_view();
        
        if (view.get_selected_count() != 1)
            return;
        
        Event? event = ((MediaSource) view.get_selected_source_at(0)).get_event();
        if (event != null)
            switch_to_event(event);
    }
    
    private void on_media_altered() {
        set_common_action_sensitive("CommonJumpToEvent", can_jump_to_event());
    }
    
    public int get_events_sort() {
        return events_sort_ascending ? SORT_EVENTS_ORDER_ASCENDING : SORT_EVENTS_ORDER_DESCENDING;
    }    

    private void on_sort_events() {
        // any member of the group can be told the current value
        Gtk.RadioAction action = (Gtk.RadioAction) get_current_page().common_action_group.get_action(
            "CommonSortEventsAscending");
        assert(action != null);

        action.set_current_value(get_events_sort());
    }
    
    private void on_events_sort_changed() {
        // any member of the group knows the value
        Gtk.RadioAction action = (Gtk.RadioAction) get_current_page().common_action_group.get_action(
            "CommonSortEventsAscending");
        assert(action != null);
        
        int new_events_sort = action.get_current_value();
        
        // don't resort if the order hasn't changed
        if (new_events_sort == get_events_sort())
            return;
        
        events_sort_ascending = new_events_sort == SORT_EVENTS_ORDER_ASCENDING;
        Config.get_instance().set_events_sort_ascending(events_sort_ascending);
       
        sidebar.sort_branch(events_directory_page.get_marker(), 
            get_event_branch_comparator(new_events_sort));

        // the events directory pages need to know about resort
        foreach (SubEventsDirectoryPage.Stub events_dir in events_dir_list) {
            if (events_dir.has_page())
                ((SubEventsDirectoryPage) events_dir.get_page()).notify_sort_changed();
        }
        
        // set the tree cursor to the current page, which might have been lost in the
        // delete/insert
        sidebar.place_cursor(get_current_page());

        // the events directory page needs to know about this
        if (events_directory_page.has_page())
            ((MasterEventsDirectoryPage) events_directory_page.get_page()).notify_sort_changed();
    }
    
    private void on_preferences() {
        PreferencesDialog.show();
    }
    
    private void on_display_basic_properties(Gtk.Action action) {
        bool display = ((Gtk.ToggleAction) action).get_active();

        if (display) {
            basic_properties.update_properties(get_current_page());
            bottom_frame.show();
        } else {
            if (sidebar_paned.child2 != null) {
                bottom_frame.hide();
            }
        }

        // sync the setting so it will persist
        Config.get_instance().set_display_basic_properties(display);
    }

    private void on_display_extended_properties(Gtk.Action action) {
        bool display = ((Gtk.ToggleAction) action).get_active();

        if (display) {
            extended_properties.update_properties(get_current_page());
            extended_properties.show_all();
        } else {
            extended_properties.hide();
        }
    }

    private void show_extended_properties() {
        sync_extended_properties(true);
    }

    private void hide_extended_properties() {
        sync_extended_properties(false);
    }

    private void sync_extended_properties(bool show) {
        Gtk.ToggleAction extended_display_action = 
            (Gtk.ToggleAction) get_current_page().common_action_group.get_action(
            "CommonDisplayExtendedProperties");
        assert(extended_display_action != null);
        extended_display_action.set_active(show);

        // sync the setting so it will persist
        Config.get_instance().set_display_extended_properties(show);
    }

    public void enqueue_batch_import(BatchImport batch_import, bool allow_user_cancel) {
        if (!displaying_import_queue_page) {
            insert_page_before(events_directory_page.get_marker(), import_queue_page);
            displaying_import_queue_page = true;
        }
        
        import_queue_page.enqueue_and_schedule(batch_import, allow_user_cancel);
    }
    
    private void sync_last_import_visibility() {
        bool has_last_import = false;
        foreach (MediaSourceCollection sources in MediaCollectionRegistry.get_instance().get_all()) {
            if (sources.get_last_import_id() != null) {
                has_last_import = true;
                
                break;
            }
        }
        
        enable_disable_last_import_page(has_last_import);
    }
    
    private void sync_flagged_visibility() {
        bool has_flagged = false;
        foreach (MediaSourceCollection sources in MediaCollectionRegistry.get_instance().get_all()) {
            if (sources.get_flagged().size > 0) {
                has_flagged = true;
                
                break;
            }
        }
        
        enable_disable_flagged_page(has_flagged);
    }
    
    private void sync_videos_visibility() {
        enable_disable_videos_page(Video.global.get_count() > 0);
    }
    
    private void import_queue_batch_finished() {
        if (displaying_import_queue_page && import_queue_page.get_batch_count() == 0) {
            // only hide the import queue page, as it might be used later
            hide_page(import_queue_page, library_page);
            displaying_import_queue_page = false;
        }
    }
    
    private void import_reporter(ImportManifest manifest) {
        ImportUI.report_manifest(manifest, true);
    }

    private void dispatch_import_jobs(GLib.SList<string> uris, string job_name, bool copy_to_library) {
        if (AppDirs.get_import_dir().get_path() == Environment.get_home_dir() && notify_library_is_home_dir) {
            Gtk.ResponseType response = AppWindow.affirm_cancel_question(
                _("Shotwell is configured to import photos to your home directory.\n" + 
                "We recommend changing this in <span weight=\"bold\">Edit %s Preferences</span>.\n" + 
                "Do you want to continue importing photos?").printf("▸"),
                _("_Import"), _("Library Location"), AppWindow.get_instance());
            
            if (response == Gtk.ResponseType.CANCEL)
                return;
            
            notify_library_is_home_dir = false;
        }
        
        Gee.ArrayList<FileImportJob> jobs = new Gee.ArrayList<FileImportJob>();
        foreach (string uri in uris) {
            File file_or_dir = File.new_for_uri(uri);
            if (file_or_dir.get_path() == null) {
                // TODO: Specify which directory/file.
                AppWindow.error_message(_("Photos cannot be imported from this directory."));
                
                continue;
            }

            jobs.add(new FileImportJob(file_or_dir, copy_to_library));
        }
        
        if (jobs.size > 0) {
            BatchImport batch_import = new BatchImport(jobs, job_name, import_reporter);
            enqueue_batch_import(batch_import, true);
            switch_to_import_queue_page();
        }
    }
    
    private Gdk.DragAction get_drag_action() {
        Gdk.ModifierType mask;
        
        window.get_pointer(null, null, out mask);

        bool ctrl = (mask & Gdk.ModifierType.CONTROL_MASK) != 0;
        bool alt = (mask & Gdk.ModifierType.MOD1_MASK) != 0;
        bool shift = (mask & Gdk.ModifierType.SHIFT_MASK) != 0;
        
        if (ctrl && !alt && !shift)
            return Gdk.DragAction.COPY;
        else if (!ctrl && alt && !shift)
            return Gdk.DragAction.ASK;
        else if (ctrl && !alt && shift)
            return Gdk.DragAction.LINK;
        else
            return Gdk.DragAction.DEFAULT;
    }
    
    public override bool drag_motion(Gdk.DragContext context, int x, int y, uint time) {
        Gdk.Atom target = Gtk.drag_dest_find_target(this, context, Gtk.drag_dest_get_target_list(this));
        if (((int) target) == ((int) Gdk.Atom.NONE)) {
            debug("drag target is GDK_NONE");
            Gdk.drag_status(context, 0, time);
            
            return true;
        }
        
        // internal drag
        if (Gtk.drag_get_source_widget(context) != null) {
            Gdk.drag_status(context, Gdk.DragAction.PRIVATE, time);
            
            return true;
        }
        
        // since we cannot set a default action, we must set it when we spy a drag motion
        Gdk.DragAction drag_action = get_drag_action();
        
        if (drag_action == Gdk.DragAction.DEFAULT)
            drag_action = Gdk.DragAction.ASK;
        
        Gdk.drag_status(context, drag_action, time);

        return true;
    }
    
    public override void drag_data_received(Gdk.DragContext context, int x, int y,
        Gtk.SelectionData selection_data, uint info, uint time) {
        if (selection_data.length < 0)
            debug("failed to retrieve SelectionData");
        
        drop_received(context, x, y, selection_data, info, time, null, null);
    }

    private void drop_received(Gdk.DragContext context, int x, int y,
        Gtk.SelectionData selection_data, uint info, uint time, Gtk.TreePath? path, 
        SidebarPage? page) {
        // determine if drag is internal or external
        if (Gtk.drag_get_source_widget(context) != null)
            drop_internal(context, x, y, selection_data, info, time, path, page);
        else
            drop_external(context, x, y, selection_data, info, time);
    }

    private void drop_internal(Gdk.DragContext context, int x, int y,
        Gtk.SelectionData selection_data, uint info, uint time, Gtk.TreePath? path,
        SidebarPage? page = null) {
		Gee.List<MediaSource>? media = unserialize_media_sources(selection_data.data,
            selection_data.get_length());
        
        if (media.size == 0) {
            Gtk.drag_finish(context, false, false, time);
            
            return;
        }
        
        bool success = false;
        if (page is EventPage.Stub) {
            Event event = ((EventPage.Stub) page).event;

            Gee.ArrayList<ThumbnailView> views = new Gee.ArrayList<ThumbnailView>();
            foreach (MediaSource current_media in media) {
                // don't move a photo into the event it already exists in
                if (current_media.get_event() == null || !current_media.get_event().equals(event))
                    views.add(new ThumbnailView(current_media));
            }

            if (views.size > 0) {
                get_command_manager().execute(new SetEventCommand(views, event));
                success = true;
            }
        } else if (page is TagPage.Stub) {
            get_command_manager().execute(new TagUntagPhotosCommand(((TagPage.Stub) page).tag, media, 
                media.size, true));
            success = true;
        } else if (page is TrashPage.Stub) {
            get_command_manager().execute(new TrashUntrashPhotosCommand(media, true));
            success = true;
        } else if ((path != null) && (tags_marker != null) && (tags_marker.get_path() != null) && 
                   (path.compare(tags_marker.get_path()) == 0)) {
            AddTagsDialog dialog = new AddTagsDialog();
            string[]? names = dialog.execute();
            if (names != null) {
                get_command_manager().execute(new AddTagsCommand(names, media));
                success = true;
            }
        }
        
        Gtk.drag_finish(context, success, false, time);
    }

    private void drop_external(Gdk.DragContext context, int x, int y,
        Gtk.SelectionData selection_data, uint info, uint time) {
        // We extract the URI list using Uri.list_extract_uris() rather than
        // Gtk.SelectionData.get_uris() to work around this bug on Windows:
        // https://bugzilla.gnome.org/show_bug.cgi?id=599321
        string uri_string = (string) selection_data.data;
        string[] uris_array = Uri.list_extract_uris(uri_string);
        
        GLib.SList<string> uris = new GLib.SList<string>();
        foreach (string uri in uris_array)
            uris.append(uri);
        
        if (context.action == Gdk.DragAction.ASK) {
            // Default action is to link, unless one or more URIs are external to the library
            Gtk.ResponseType result = Gtk.ResponseType.REJECT;
            foreach (string uri in uris) {
                if (!AppDirs.is_in_import_dir(File.new_for_uri(uri))) {
                    result = copy_files_dialog();
                    
                    break;
                }
            }
            
            switch (result) {
                case Gtk.ResponseType.ACCEPT:
                    context.action = Gdk.DragAction.COPY;
                break;
                
                case Gtk.ResponseType.REJECT:
                    context.action = Gdk.DragAction.LINK;
                break;
                
                default:
                    // cancelled
                    Gtk.drag_finish(context, false, false, time);
                    
                    return;
            }
        }
        
        dispatch_import_jobs(uris, "drag-and-drop", context.action == Gdk.DragAction.COPY);
        
        Gtk.drag_finish(context, true, false, time);
    }
    
    public void switch_to_library_page() {
        switch_to_page(library_page);
    }
    
    public void switch_to_events_directory_page() {
        switch_to_page(events_directory_page.get_page());
    }
    
    public void switch_to_event(Event event) {
        EventPage page = load_event_page(event);
        if (page == null) {
            debug("Cannot find page for event %s", event.to_string());

            return;
        }

        switch_to_page(page);
    }
    
    public void switch_to_tag(Tag tag) {
        TagPage.Stub? stub = tag_map.get(tag);
        assert(stub != null);
        
        switch_to_page(stub.get_page());
    }
    
    public void switch_to_photo_page(CollectionPage controller, Photo current) {
        if (photo_page == null) {
            photo_page = new LibraryPhotoPage();
            add_orphan_page(photo_page);
            
            // need to do this to allow the event loop a chance to map and realize the page
            // before switching to it
            spin_event_loop();
        }
        
        photo_page.display_for_collection(controller, current);
        switch_to_page(photo_page);
    }
    
    public void switch_to_import_queue_page() {
        switch_to_page(import_queue_page);
    }
    
    public EventPage? load_event_page(Event event) {
        foreach (EventPage.Stub stub in event_list) {
            if (stub.event.equals(event)) {
                // this will create the EventPage if not already created
                return (EventPage) stub.get_page();
            }
        }
        
        return null;
    }
    
    private void on_added_events(Gee.Iterable<DataObject> objects) {
        foreach (DataObject object in objects)
            add_event_page((Event) object);
    }
    
    private void on_removed_events(Gee.Iterable<DataObject> objects) {
        foreach (DataObject object in objects)
            remove_event_page((Event) object);
    }

    private void on_events_altered(Gee.Map<DataObject, Alteration> map) {
        foreach (DataObject object in map.keys) {
            Event event = (Event) object;
            
            foreach (EventPage.Stub stub in event_list) {
                if (event.equals(stub.event)) {
                    SubEventsDirectoryPage.Stub old_parent = 
                        (SubEventsDirectoryPage.Stub) sidebar.get_parent_page(stub);
                    
                    // only re-add to sidebar if the event has changed directories or shares its dir
                    if (sidebar.get_children_count(old_parent.get_marker()) > 1 || 
                        !(old_parent.get_month() == Time.local(event.get_start_time()).month &&
                         old_parent.get_year() == Time.local(event.get_start_time()).year)) {
                        // this prevents the cursor from jumping back to the library photos page
                        // should it be on this page as we re-sort by removing and reinserting it
                        sidebar.cursor_changed.disconnect(on_sidebar_cursor_changed);
                        
                        // remove from sidebar
                        remove_event_tree(stub, false);

                        // add to sidebar again
                        sidebar.insert_child_sorted(find_parent_marker(stub), stub,
                            get_event_branch_comparator(get_events_sort()));

                        sidebar.expand_tree(stub.get_marker());

                        if (get_current_page() is EventPage &&
                            ((EventPage) get_current_page()).page_event.equals(event))
                            sidebar.place_cursor(stub);
                        
                        sidebar.cursor_changed.connect(on_sidebar_cursor_changed);
                    }
                    
                    // refresh name
                    SidebarMarker marker = stub.get_marker();
                    sidebar.rename(marker, event.get_name());
                    break;
                }
            }
        }
        
        on_update_properties();
    }
    
    private void on_tags_added_removed(Gee.Iterable<DataObject>? added, Gee.Iterable<DataObject>? removed) {
        if (added != null) {
            foreach (DataObject object in added)
                add_tag_page((Tag) object);
        }
        
        if (removed != null) {
            foreach (DataObject object in removed)
                remove_tag_page((Tag) object);
        }
        
        // open Tags so user sees the new ones
        if (added != null && tags_marker != null)
            sidebar.expand_branch(tags_marker);
    }
    
    private void on_tags_altered(Gee.Map<DataObject, Alteration> map) {
        // this prevents the cursor from jumping back to the library photos page
        // should it be on this page as we re-sort by removing and reinserting it
        sidebar.cursor_changed.disconnect(on_sidebar_cursor_changed);
            
        foreach (DataObject object in map.keys) {
            TagPage.Stub page_stub = tag_map.get((Tag) object);
            assert(page_stub != null);
            
            bool expanded = sidebar.is_branch_expanded(tags_marker);
            bool selected = sidebar.is_page_selected(page_stub);
            sidebar.remove_page(page_stub);
            sidebar.insert_child_sorted(tags_marker, page_stub, tag_page_comparator);
            
            if (expanded)
                sidebar.expand_branch(tags_marker);
            
            if (selected)
                sidebar.place_cursor(page_stub);
        }
        
        sidebar.cursor_changed.connect(on_sidebar_cursor_changed);
    }

    private void sync_offline_page_state() {
        bool enable_page = (LibraryPhoto.global.get_offline_bin_contents().size > 0) ||
            (Video.global.get_offline_bin_contents().size > 0);
        enable_disable_offline_page(enable_page);
    }
    
    private void on_offline_contents_altered() {
        sync_offline_page_state();
    }
    
    private SidebarMarker? find_parent_marker(PageStub page) {
        // EventPageStub
        if (page is EventPage.Stub) {
            time_t event_time = ((EventPage.Stub) page).event.get_start_time();

            SubEventsDirectoryPage.DirectoryType type = (event_time != 0 ?
                SubEventsDirectoryPage.DirectoryType.MONTH :
                SubEventsDirectoryPage.DirectoryType.UNDATED);

            SubEventsDirectoryPage.Stub month = find_event_dir_page(type, Time.local(event_time));

            // if a month directory already exists, return it, otherwise, create a new one
            return (month != null ? month : create_event_dir_page(type,
                Time.local(event_time))).get_marker();
        } else if (page is SubEventsDirectoryPage.Stub) {
            SubEventsDirectoryPage.Stub event_dir_page = (SubEventsDirectoryPage.Stub) page;
            // SubEventsDirectoryPageStub Month
            if (event_dir_page.type == SubEventsDirectoryPage.DirectoryType.MONTH) {
                SubEventsDirectoryPage.Stub year = find_event_dir_page(
                    SubEventsDirectoryPage.DirectoryType.YEAR, event_dir_page.time);

                // if a month directory already exists, return it, otherwise, create a new one
                return (year != null ? year : create_event_dir_page(
                    SubEventsDirectoryPage.DirectoryType.YEAR, event_dir_page.time)).get_marker();
            }
            
            // SubEventsDirectoryPageStub Year && Undated
            return events_directory_page.get_marker();
        } else if (page is TagPage.Stub) {
            return tags_marker;
        }

        return null;
    }
    
    private SubEventsDirectoryPage.Stub? find_event_dir_page(SubEventsDirectoryPage.DirectoryType type, Time time) {
        foreach (SubEventsDirectoryPage.Stub dir in events_dir_list) {
            if (dir.matches(type,  time))
                return dir;
        }

        return null;
    }

    private SubEventsDirectoryPage.Stub create_event_dir_page(SubEventsDirectoryPage.DirectoryType type, Time time) {
        Comparator comparator = get_event_branch_comparator(get_events_sort());
        
        SubEventsDirectoryPage.Stub new_dir = SubEventsDirectoryPage.create_stub(type, time);

        sidebar.insert_child_sorted(find_parent_marker(new_dir), new_dir,
            comparator);

        events_dir_list.add(new_dir);

        return new_dir;
    }
    
    private int64 tag_page_comparator(void *a, void *b) {
        Tag atag = ((TagPage.Stub *) a)->tag;
        Tag btag = ((TagPage.Stub *) b)->tag;
        
        return atag.get_name().collate(btag.get_name());
    }
    
    private void add_tag_page(Tag tag) {
        if (tags_marker == null) {
            tags_marker = sidebar.insert_grouping_after(events_directory_page.get_marker(),
                _("Tags"), Resources.ICON_TAGS);
        }
        
        TagPage.Stub stub = TagPage.create_stub(tag);
        sidebar.insert_child_sorted(tags_marker, stub, tag_page_comparator);
        tag_map.set(tag, stub);
    }
    
    private void remove_tag_page(Tag tag) {
        TagPage.Stub stub = tag_map.get(tag);
        assert(stub != null);
        
        remove_stub(stub, library_page, null);
        
        if (tag_map.size == 0 && tags_marker != null) {
            sidebar.prune_branch(tags_marker);
            tags_marker = null;
        }
    }
    
    private void on_no_event_collection_altered() {
        enable_disable_no_event_page(Event.global.get_no_event_objects().size > 0);
    }
    
    private void enable_disable_no_event_page(bool enable) {
        if (enable && no_event_page == null) {
            no_event_page = NoEventPage.create_stub();
            sidebar.add_child(events_directory_page.get_marker(), no_event_page);
        } else if (!enable && no_event_page != null) {
            remove_stub(no_event_page, null, events_directory_page);
            no_event_page = null;
        }
    }
    
    private void enable_disable_offline_page(bool enable) {
        if (enable && offline_page == null) {
            offline_page = OfflinePage.create_stub();
            sidebar.add_parent(offline_page);
        } else if (!enable && offline_page != null) {
            remove_stub(offline_page, library_page, null);
            offline_page = null;
        }
    }

    private void enable_disable_last_import_page(bool enable) {
        if (enable && last_import_page == null) {
            last_import_page = LastImportPage.create_stub();
            sidebar.insert_sibling_after(library_page.get_marker(), last_import_page);
        } else if (!enable && last_import_page != null) {
            remove_stub(last_import_page, library_page, null);
            last_import_page = null;
        }
    }
    
    private void enable_disable_flagged_page(bool enable) {
        if (enable && flagged_page == null) {
            flagged_page = FlaggedPage.create_stub();
            sidebar.insert_sibling_before(events_directory_page.get_marker(), flagged_page);
        } else if (!enable && flagged_page != null) {
            remove_stub(flagged_page, library_page, null);
            flagged_page = null;
        }
    }
    
    private void enable_disable_videos_page(bool enable) {
        if (enable && videos_page == null) {
            videos_page = VideosPage.create_stub();
            sidebar.insert_sibling_after(library_page.get_marker(), videos_page);
        } else if (!enable && videos_page != null) {
            remove_stub(videos_page, library_page, null);
            videos_page = null;
        }
    }
    
    private void add_event_page(Event event) {
        EventPage.Stub event_stub = EventPage.create_stub(event);
        
        sidebar.insert_child_sorted(find_parent_marker(event_stub), event_stub,
            get_event_branch_comparator(get_events_sort()));
        
        event_list.add(event_stub);
    }
    
    private void remove_event_page(Event event) {
        // don't use load_event_page, because that will create an EventPage (which we're simply
        // going to remove)
        EventPage.Stub event_stub = null;
        foreach (EventPage.Stub stub in event_list) {
            if (stub.event.equals(event)) {
                event_stub = stub;
                
                break;
            }
        }
        
        if (event_stub == null)
            return;
        
        // remove from sidebar
        remove_event_tree(event_stub);
        
        // jump to the Events page
        if (event_stub.has_page() && event_stub.get_page() == get_current_page())
            switch_to_events_directory_page();
    }

    private void remove_event_tree(PageStub stub, bool delete_stub = true) {
        // grab parent page
        SidebarPage parent = sidebar.get_parent_page(stub);
        
        // remove from notebook and sidebar
        if (delete_stub)
            remove_stub(stub, null, events_directory_page);
        else
            sidebar.remove_page(stub);
        
        // remove parent if empty
        if (parent != null && !(parent is MasterEventsDirectoryPage.Stub)) {
            assert(parent is PageStub);
            
            if (!sidebar.has_children(parent.get_marker()))
                remove_event_tree((PageStub) parent);
        }
    }
    
#if !NO_CAMERA
    private void add_camera_page(DiscoveredCamera camera) {
        ImportPage page = new ImportPage(camera.gcamera, camera.uri);   

        // create the Cameras row if this is the first one
        if (cameras_marker == null)
            cameras_marker = sidebar.insert_grouping_after(library_page.get_marker(),
                _("Cameras"), Resources.ICON_CAMERAS);
        
        camera_pages.set(camera.uri, page);
        add_child_page(cameras_marker, page);

        // automagically expand the Cameras branch so the user sees the attached camera(s)
        sidebar.expand_branch(cameras_marker);
        
        // if this page is for a camera which initialized the app, we want to switch to that page
        if (initial_camera_uris.contains(page.get_uri())) {
            File uri_file = File.new_for_uri(page.get_uri());//page.get_uri());
            
            // find the VFS mount point
            Mount mount = null;
            try {
                mount = uri_file.find_enclosing_mount(null);
            } catch (Error err) {
                // error means not mounted
            }
            
            // don't unmount mass storage cameras, as they are then unavailable to gPhoto
            if (mount != null && !camera.uri.has_prefix("file://")) {
                if (page.unmount_camera(mount))
                    switch_to_page(page);
                else
                    error_message("Unable to unmount the camera at this time.");
            } else {
                switch_to_page(page);
            }
        }
    }
    
    private void remove_camera_page(DiscoveredCamera camera) {
        // remove from page table and then from the notebook
        ImportPage page = camera_pages.get(camera.uri);
        camera_pages.unset(camera.uri);
        remove_page(page, library_page);

        // if no cameras present, remove row
        if (CameraTable.get_instance().get_count() == 0 && cameras_marker != null) {
            sidebar.prune_branch(cameras_marker);
            cameras_marker = null;
        }
    }
#endif
    
    private PageLayout? get_page_layout(Page page) {
        return page_layouts.get(page);
    }
    
    private PageLayout create_page_layout(Page page) {
        PageLayout layout = new PageLayout(page);
        page_layouts.set(page, layout);
        
        return layout;
    }
    
    private bool destroy_page_layout(Page page) {
        PageLayout? layout = get_page_layout(page);
        if (layout == null)
            return false;
        
        // destroy the layout, which destroys the page
        layout.destroy();
        
        bool unset = page_layouts.unset(page);
        assert(unset);
        
        return true;
    }
    
    // This should only be called by LibraryWindow and PageStub.
    public void add_to_notebook(Page page) {
        // get/create layout for this page (if the page is hidden the layout has already been
        // created)
        PageLayout? layout = get_page_layout(page);
        if (layout == null)
            layout = create_page_layout(page);
        
        // need to show all before handing over to notebook
        layout.show_all();
        
        int pos = notebook.append_page(layout, null);
        assert(pos >= 0);
        
        // need to show_all() after pages are added and removed
        notebook.show_all();
    }
    
    private void remove_from_notebook(Page page) {
        notebook.remove_page(get_notebook_pos(page));
        
        // need to show_all() after pages are added and removed
        notebook.show_all();
    }
    
    private int get_notebook_pos(Page page) {
        PageLayout? layout = get_page_layout(page);
        assert(layout != null);
        
        int pos = notebook.page_num(layout);
        assert(pos != -1);
        
        return pos;
    }
    
    private void add_parent_page(Page parent) {
        add_to_notebook(parent);

        sidebar.add_parent(parent);
    }

#if !NO_CAMERA    
    private void add_child_page(SidebarMarker parent_marker, Page child) {
        add_to_notebook(child);
        
        sidebar.add_child(parent_marker, child);
    }
#endif
    
    private void insert_page_before(SidebarMarker before_marker, Page page) {
        add_to_notebook(page);
        
        sidebar.insert_sibling_before(before_marker, page);
    }
    
    // an orphan page is a Page that exists in the notebook (and can therefore be switched to) but
    // is not listed in the sidebar
    private void add_orphan_page(Page orphan) {
        add_to_notebook(orphan);
    }
    
    // This removes the page from the notebook and the sidebar, but does not actually notify it
    // that it's been removed from the system, allowing it to be added back later.
    private void hide_page(Page page, Page fallback_page) {
        if (get_current_page() == page)
            switch_to_page(fallback_page);
        
        debug("Hiding page %s", page.get_page_name());
        
        remove_from_notebook(page);
        sidebar.remove_page(page);
        
        debug("Hid page %s", page.get_page_name());
    }
    
    private void remove_page(Page page, Page fallback_page) {
        // a handful of pages just don't go away
        assert(page != library_page);
        assert(page != photo_page);
        assert(page != import_queue_page);
        
        // switch away if necessary to ensure Page is fully detached from system
        if (get_current_page() == page)
            switch_to_page(fallback_page);
        
        debug("Removing page %s", page.get_page_name());
        
        // detach from notebook and sidebar
        sidebar.remove_page(page);
        remove_from_notebook(page);
        
        // destroy layout if it exists, otherwise just the page
        if (!destroy_page_layout(page))
            page.destroy();
        
        debug("Removed page %s", page.get_page_name());
    }
    
    private void remove_stub(PageStub stub, Page? fallback_page, PageStub? fallback_stub) {
        // remove from appropriate list
        if (stub is SubEventsDirectoryPage.Stub) {
            // remove from events directory list 
            bool removed = events_dir_list.remove((SubEventsDirectoryPage.Stub) stub);
            assert(removed);
        } else if (stub is EventPage.Stub) {
            // remove from the events list
            bool removed = event_list.remove((EventPage.Stub) stub);
            assert(removed);
        } else if (stub is TagPage.Stub) {
            bool removed = tag_map.unset(((TagPage.Stub) stub).tag);
            assert(removed);
        }
        
        // remove stub (which holds a marker) from the sidebar
        sidebar.remove_page(stub);
        
        if (stub.has_page()) {
            // ensure the page is fully detached
            if (get_current_page() == stub.get_page()) {
                if (fallback_page != null)
                    switch_to_page(fallback_page);
                else if (fallback_stub != null)
                    switch_to_page(fallback_stub.get_page());
            }
            
            // detach from notebook
            remove_from_notebook(stub.get_page());
            
            // destroy page layout if it exists, otherwise just the page
            if (!destroy_page_layout(stub.get_page()))
                stub.get_page().destroy();
        }
    }
    
    // check for settings that should persist between instances
    private void load_configuration() {
        Gtk.ToggleAction basic_display_action = 
            (Gtk.ToggleAction) get_current_page().common_action_group.get_action(
            "CommonDisplayBasicProperties");
        assert(basic_display_action != null);
        basic_display_action.set_active(Config.get_instance().get_display_basic_properties());

        Gtk.ToggleAction extended_display_action = 
            (Gtk.ToggleAction) get_current_page().common_action_group.get_action(
            "CommonDisplayExtendedProperties");
        assert(extended_display_action != null);
        extended_display_action.set_active(Config.get_instance().get_display_extended_properties());

        Gtk.RadioAction sort_events_action = (Gtk.RadioAction) get_current_page().common_action_group.get_action("CommonSortEventsAscending");
        assert(sort_events_action != null);
        events_sort_ascending = Config.get_instance().get_events_sort_ascending();
        sort_events_action.set_active(events_sort_ascending);
    }
    
    private void pulse_background_progress_bar(string label, int priority) {
        if (priority < current_progress_priority)
            return;
        
        current_progress_priority = priority;
        
        background_progress_bar.set_text(label);
        background_progress_bar.pulse();
        show_background_progress_bar();
    }
    
    private void update_background_progress_bar(string label, int priority, double count,
        double total) {
        if (priority < current_progress_priority)
            return;
        
        if (count <= 0.0 || total <= 0.0 || count >= total) {
            clear_background_progress_bar();
            
            return;
        }
        
        current_progress_priority = priority;
        
        double fraction = count / total;
        background_progress_bar.set_fraction(fraction);
        background_progress_bar.set_text(_("%s (%d%%)").printf(label, (int) (fraction * 100.0)));
        show_background_progress_bar();
    }
    
    private void clear_background_progress_bar() {
        current_progress_priority = 0;
        
        background_progress_bar.set_fraction(0.0);
        background_progress_bar.set_text("");
        hide_background_progress_bar();
    }
    
    private void show_background_progress_bar() {
        if (!background_progress_displayed) {
            top_section.pack_end(background_progress_frame, false, false, 0);
            background_progress_frame.show_all();
            background_progress_displayed = true;
        }
    }
    
    private void hide_background_progress_bar() {
        if (background_progress_displayed) {
            top_section.remove(background_progress_frame);
            background_progress_displayed = false;
        }
    }
    
    private void on_library_monitor_auto_update_progress(int completed_files, int total_files) {
        update_background_progress_bar(_("Updating library..."), REALTIME_UPDATE_PROGRESS_PRIORITY,
            completed_files, total_files);
    }
    
    private void on_library_monitor_auto_import_preparing() {
        pulse_background_progress_bar(_("Preparing to auto-import photos..."),
            REALTIME_IMPORT_PROGRESS_PRIORITY);
    }
    
    private void on_library_monitor_auto_import_progress(uint64 completed_bytes, uint64 total_bytes) {
        update_background_progress_bar(_("Auto-importing photos..."),
            REALTIME_IMPORT_PROGRESS_PRIORITY, completed_bytes, total_bytes);
    }
    
    private void on_metadata_writer_progress(uint completed, uint total) {
        update_background_progress_bar(_("Writing metadata to files..."),
            METADATA_WRITER_PROGRESS_PRIORITY, completed, total);
    }
    
    private void on_mimic_manager_progress(int completed, int total) {
        update_background_progress_bar(_("Processing RAW files..."),
            MIMIC_MANAGER_PROGRESS_PRIORITY, completed, total);
    }
    
    private void create_layout(Page start_page) {
        // use a Notebook to hold all the pages, which are switched when a sidebar child is selected
        notebook.set_show_tabs(false);
        notebook.set_show_border(false);
        
        Gtk.Settings settings = Gtk.Settings.get_default();
        HashTable<string, Gdk.Color?> color_table = settings.color_hash;
        Gdk.Color? base_color = color_table.lookup("base_color");
        if (base_color != null && (base_color.red > STANDARD_COMPONENT_MINIMUM &&
            base_color.green > STANDARD_COMPONENT_MINIMUM &&
            base_color.blue > STANDARD_COMPONENT_MINIMUM)) {
            // if the current theme is a standard theme (as opposed to a dark theme), then
            // use the specially-selected Yorba muted background color for the sidebar.
            // otherwise, use the theme's native background color.
            sidebar.modify_base(Gtk.StateType.NORMAL, SIDEBAR_STANDARD_BG_COLOR);
        }
        
        // put the sidebar in a scrolling window
        Gtk.ScrolledWindow scrolled_sidebar = new Gtk.ScrolledWindow(null, null);
        scrolled_sidebar.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scrolled_sidebar.add(sidebar);

        // divy the sidebar up into selection tree list, background progress bar, and properties
        Gtk.Frame top_frame = new Gtk.Frame(null);
        top_frame.add(scrolled_sidebar);
        top_frame.set_shadow_type(Gtk.ShadowType.IN);
        
        background_progress_frame.add(background_progress_bar);
        background_progress_frame.set_shadow_type(Gtk.ShadowType.IN);

        // pad the bottom frame (properties)
        Gtk.Alignment bottom_alignment = new Gtk.Alignment(0, 0.5f, 1, 0);
        bottom_alignment.set_padding(10, 10, 6, 0);
        bottom_alignment.add(basic_properties);

        bottom_frame.add(bottom_alignment);
        bottom_frame.set_shadow_type(Gtk.ShadowType.IN);
        
        // "attach" the progress bar to the sidebar tree, so the movable ridge is to resize the
        // top two and the basic information pane
        top_section.pack_start(top_frame, true, true, 0);

        sidebar_paned.pack1(top_section, true, false);
        sidebar_paned.pack2(bottom_frame, false, false);
        sidebar_paned.set_position(1000);

        // layout the selection tree to the left of the collection/toolbar box with an adjustable
        // gutter between them, framed for presentation
        Gtk.Frame right_frame = new Gtk.Frame(null);
        right_frame.add(notebook);
        right_frame.set_shadow_type(Gtk.ShadowType.IN);
        
        client_paned = new Gtk.HPaned();
        client_paned.pack1(sidebar_paned, false, false);
        sidebar.set_size_request(SIDEBAR_MIN_WIDTH, -1);
        client_paned.pack2(right_frame, true, false);
        client_paned.set_position(Config.get_instance().get_sidebar_position());
        // TODO: Calc according to layout's size, to give sidebar a maximum width
        notebook.set_size_request(PAGE_MIN_WIDTH, -1);

        layout.pack_end(client_paned, true, true, 0);
        
        add(layout);

        switch_to_page(start_page);
        start_page.grab_focus();
    }
    
    public override void set_current_page(Page page) {
        // switch_to_page() will call base.set_current_page(), maintain the semantics of this call
        switch_to_page(page);
    }
    
    public void switch_to_page(Page page) {
        if (page == get_current_page())
            return;
        
        // open sidebar directory containing page, if any
        if (page.get_marker() != null && page is EventPage)
            sidebar.expand_tree(page.get_marker());
        
        Page current_page = get_current_page();
        if (current_page != null) {
            current_page.switching_from();
            
            // see note below about why the sidebar is uneditable while the LibraryPhotoPage is
            // visible
            if (current_page is LibraryPhotoPage)
                sidebar.enable_editing();
            
            Gtk.AccelGroup accel_group = current_page.ui.get_accel_group();
            if (accel_group != null)
                remove_accel_group(accel_group);
            
            // carry over menubar toggle activity between pages
            Gtk.ToggleAction old_basic_display_action = 
                (Gtk.ToggleAction) current_page.common_action_group.get_action(
                "CommonDisplayBasicProperties");
            assert(old_basic_display_action != null);
            
            Gtk.ToggleAction new_basic_display_action = 
                (Gtk.ToggleAction) page.common_action_group.get_action(
                "CommonDisplayBasicProperties");
            assert(new_basic_display_action != null);
            
            new_basic_display_action.set_active(old_basic_display_action.get_active());
            
            Gtk.ToggleAction old_extended_display_action = 
                (Gtk.ToggleAction) current_page.common_action_group.get_action(
                "CommonDisplayExtendedProperties");
            assert(old_basic_display_action != null);
            
            Gtk.ToggleAction new_extended_display_action = 
                (Gtk.ToggleAction) page.common_action_group.get_action(
                "CommonDisplayExtendedProperties");
            assert(new_basic_display_action != null);
            
            new_extended_display_action.set_active(old_extended_display_action.get_active());
            
            // old page unsubscribes to these signals (new page subscribes below)
            unsubscribe_from_basic_information(current_page);
        }
        
        notebook.set_current_page(get_notebook_pos(page));
        
        // switch menus
        if (current_page != null)
            layout.remove(current_page.get_menubar());
        layout.pack_start(page.get_menubar(), false, false, 0);
        
        Gtk.AccelGroup accel_group = page.ui.get_accel_group();
        if (accel_group != null)
            add_accel_group(accel_group);
        
        // if the visible page is the LibraryPhotoPage, we need to prevent single-click inline
        // renaming in the sidebar because a single click while in the LibraryPhotoPage indicates
        // the user wants to return to the controlling page ... that is, in this special case, the
        // sidebar cursor is set not to the 'current' page, but the page the user came from
        if (page is LibraryPhotoPage)
            sidebar.disable_editing();
        
        // do this prior to changing selection, as the change will fire a cursor-changed event,
        // which will then call this function again
        base.set_current_page(page);
        
        sidebar.cursor_changed.disconnect(on_sidebar_cursor_changed);
        sidebar.place_cursor(page);
        sidebar.cursor_changed.connect(on_sidebar_cursor_changed);
        
        on_update_properties();
        
        page.show_all();
        
        // subscribe to these signals for each event page so basic properties display will update
        subscribe_for_basic_information(get_current_page());
        
        page.switched_to();
    }
    
    private bool is_page_selected(SidebarPage page, Gtk.TreePath path) {
        SidebarMarker? marker = page.get_marker();
        
        return marker != null ? path.compare(marker.get_row().get_path()) == 0 : false;
    }
    
    private bool select_from_collection(Gtk.TreePath path, Gee.Collection<PageStub> stubs) {
        foreach (PageStub stub in stubs) {
            if (is_page_selected(stub, path)) {
                switch_to_page(stub.get_page());
                
                return true;
            }
        }
        
        return false;
    }
    
    private bool is_camera_selected(Gtk.TreePath path) {
#if !NO_CAMERA
        foreach (ImportPage page in camera_pages.values) {
            if (is_page_selected(page, path)) {
                switch_to_page(page);
                
                return true;
            }
        }
#endif
        return false;
    }
    
    private bool is_events_directory_selected(Gtk.TreePath path) {
        return select_from_collection(path, events_dir_list);
    }
    
    private bool is_event_selected(Gtk.TreePath path) {
        return select_from_collection(path, event_list);
    }

    private bool is_no_event_selected(Gtk.TreePath path) {
        if (no_event_page != null && is_page_selected(no_event_page, path)) {
            switch_to_page(no_event_page.get_page());
            
            return true;
        }
        
        return false;
    }
    
    private bool is_tag_selected(Gtk.TreePath path) {
        return select_from_collection(path, tag_map.values);
    }
    
    private void on_sidebar_cursor_changed() {
        Gtk.TreePath path;
        sidebar.get_cursor(out path, null);
        
        if (is_page_selected(library_page, path)) {
            switch_to_library_page();
        } else if (is_page_selected(events_directory_page, path)) {
            switch_to_events_directory_page();
        } else if (import_queue_page != null && is_page_selected(import_queue_page, path)) {
            switch_to_import_queue_page();
        } else if (is_camera_selected(path)) {
            // camera path selected and updated
        } else if (is_events_directory_selected(path)) {
            // events directory page selected and updated
        } else if (is_event_selected(path)) {
            // event page selected and updated
        } else if (is_no_event_selected(path)) {
            // no event page selected and updated
        } else if (is_tag_selected(path)) {
            // tag page selected and updated
        } else if (is_page_selected(trash_page, path)) {
            switch_to_page(trash_page.get_page());
        } else if (offline_page != null && is_page_selected(offline_page, path)) {
            switch_to_page(offline_page.get_page());
        } else if (last_import_page != null && is_page_selected(last_import_page, path)) {
            switch_to_page(last_import_page.get_page());
        } else if (flagged_page != null && is_page_selected(flagged_page, path)) {
            switch_to_page(flagged_page.get_page());
        } else if (videos_page != null && is_page_selected(videos_page, path)) {
            switch_to_page(videos_page.get_page());
        } else {
            // nothing recognized selected
        }
    }
    
    private void subscribe_for_basic_information(Page page) {
        ViewCollection view = page.get_view();
        
        view.items_state_changed.connect(on_update_properties);
        view.items_altered.connect(on_update_properties);
        view.contents_altered.connect(on_update_properties);
        view.items_visibility_changed.connect(on_update_properties);
    }
    
    private void unsubscribe_from_basic_information(Page page) {
        ViewCollection view = page.get_view();
        
        view.items_state_changed.disconnect(on_update_properties);
        view.items_altered.disconnect(on_update_properties);
        view.contents_altered.disconnect(on_update_properties);
        view.items_visibility_changed.disconnect(on_update_properties);
    }
    
    private void on_update_properties() {
        properties_scheduler.at_idle();
    }
    
    private void on_update_properties_now() {
        if (bottom_frame.visible)
            basic_properties.update_properties(get_current_page());

        if (extended_properties.visible)
            extended_properties.update_properties(get_current_page());
    }
    
#if !NO_CAMERA
    public void mounted_camera_shell_notification(string uri, bool at_startup) {
        debug("mount point reported: %s", uri);
        
        // ignore unsupport mount URIs
        if (!is_mount_uri_supported(uri)) {
            debug("Unsupported mount scheme: %s", uri);
            
            return;
        }
        
        File uri_file = File.new_for_uri(uri);
        
        // find the VFS mount point
        Mount mount = null;
        try {
            mount = uri_file.find_enclosing_mount(null);
        } catch (Error err) {
            debug("%s", err.message);
            
            return;
        }
        
        // convert file: URIs into gphoto disk: URIs
        string alt_uri = null;
        if (uri.has_prefix("file://"))
            alt_uri = CameraTable.get_port_uri(uri.replace("file://", "disk:"));
        
        // we only add uris when the notification is called on startup
        if (at_startup) {
            if (!is_string_empty(uri))
                initial_camera_uris.add(uri);

            if (!is_string_empty(alt_uri))
                initial_camera_uris.add(alt_uri);
        }
    }
#endif
    
    public override bool key_press_event(Gdk.EventKey event) {        
        return (sidebar.has_focus && Gdk.keyval_name(event.keyval) == "F2") ?
            sidebar.key_press_event(event) : base.key_press_event(event);
    }

    public void sidebar_rename_in_place(Page page) {
        sidebar.expand_tree(page.get_marker());
        sidebar.place_cursor(page);
        sidebar.rename_in_place();
    }
    
    public override bool pause_keyboard_trapping() {
        if (base.pause_keyboard_trapping()) {
            paused_accel_group = get_current_page().ui.get_accel_group();
            if (paused_accel_group != null)
                AppWindow.get_instance().remove_accel_group(paused_accel_group);
            
            return true;
        }
        
        return false;
    }
    
    public override bool resume_keyboard_trapping() {
        if (base.resume_keyboard_trapping()) {
            if (paused_accel_group != null) {
                AppWindow.get_instance().add_accel_group(paused_accel_group);
                paused_accel_group = null;
            }
            
            return true;
        }
        
        return false;
    }
}


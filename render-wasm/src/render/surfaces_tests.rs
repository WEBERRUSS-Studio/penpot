use super::*;

fn fill_cache(cache: &mut TileTextureCache, view: &Viewbox) -> HashMap<TileCacheKey, Rect> {
    let tile_view = TileViewbox::new_with_interest(view, 0);
    let mut docs = HashMap::new();
    for y in tile_view.visible_rect.top()..=tile_view.visible_rect.bottom() {
        for x in tile_view.visible_rect.left()..=tile_view.visible_rect.right() {
            let tile = Tile(x, y);
            let scale = view.get_scale();
            cache.add(&tile_view, &tile, scale, view.area, &mut docs);
            docs.insert(
                TileCacheKey::new(tile, scale),
                tiles::get_tile_rect(tile, scale),
            );
        }
    }
    docs
}

#[test]
fn doc_atlas_keeps_render_density_on_hidpi_viewports() {
    // A 1440x900 viewport at dpr 2: the old cap of 1 px per doc px stored the
    // backdrop at half the density of the tiles, and draw_atlas_to_backbuffer
    // scaled it back up by 2. The backdrop only has to cover the viewport, so
    // the render density fits inside the same memory budget as before.
    let view = Rect::from_xywh(0.0, 0.0, 1440.0, 900.0);
    let tile = Rect::from_xywh(512.0, 256.0, 512.0, 512.0);
    let (origin, size, scale) = doc_atlas_layout(tile, view, 2.0, 8192.0);

    assert!(
        (scale - 2.0).abs() < 1e-3,
        "atlas holds {scale} px per doc px, tiles render at 2.0"
    );
    assert_eq!((size.width, size.height), (2880, 1800));
    assert!(doc_atlas_covers(origin, size, scale, view));
}

#[test]
fn doc_atlas_needs_the_surface_cap_not_the_tile_texture_cap() {
    // Same window, only the side limit differs. The tile texture cap (4096)
    // forces a 2560 CSS px window at dpr 2 down to 1.6 px per doc px, which is
    // the soft look at large window sizes. The surface cap (8192, what the
    // canvas itself is allowed to be) keeps the render density and still fits
    // the pixel budget.
    let view = Rect::from_xywh(0.0, 0.0, 2560.0, 1440.0);
    let tile = Rect::from_xywh(512.0, 512.0, 512.0, 512.0);

    let (_, _, texture_cap_scale) = doc_atlas_layout(tile, view, 2.0, 4096.0);
    let (_, size, surface_cap_scale) = doc_atlas_layout(tile, view, 2.0, 8192.0);

    assert!(
        (texture_cap_scale - 1.6).abs() < 1e-2,
        "texture cap gives {texture_cap_scale} px per doc px"
    );
    assert!(
        (surface_cap_scale - 2.0).abs() < 1e-3,
        "surface cap gives {surface_cap_scale} px per doc px"
    );

    let pixels = (size.width as f32) * (size.height as f32);
    assert!(size.width <= 8192 && size.height <= 8192);
    assert!(
        pixels <= DOC_ATLAS_MAX_PIXELS * 1.01,
        "atlas is {pixels} px"
    );
}

#[test]
fn doc_atlas_follows_the_viewport_instead_of_stretching_to_far_tiles() {
    // A tile far outside the viewport must not stretch the atlas across 120000
    // px of document: that spends the budget on empty space and downscales the
    // part the user looks at. The tile is refused and stays sharp in the tile
    // cache; the window keeps the viewport at full density.
    let view = Rect::from_xywh(0.0, 0.0, 2560.0, 1440.0);
    let far = Rect::from_xywh(120_000.0, 90_000.0, 512.0, 512.0);
    let (origin, size, scale) = doc_atlas_layout(far, view, 2.0, 8192.0);

    assert!(!doc_atlas_covers(origin, size, scale, far));
    assert!(doc_atlas_covers(origin, size, scale, view));
    assert!(
        (scale - 2.0).abs() < 1e-3,
        "atlas density dropped to {scale}"
    );

    let pixels = (size.width as f32) * (size.height as f32);
    assert!(
        pixels <= DOC_ATLAS_MAX_PIXELS * 1.01,
        "atlas is {pixels} px"
    );
}

#[test]
fn doc_atlas_stays_inside_the_gpu_side_limit() {
    // A viewport larger than the texture limit: density drops to fit, and the
    // window still covers what it drew.
    let view = Rect::from_xywh(0.0, 0.0, 8000.0, 6000.0);
    let tile = Rect::from_xywh(7000.0, 5000.0, 512.0, 512.0);
    let (origin, size, scale) = doc_atlas_layout(tile, view, 2.0, 4096.0);

    assert!(size.width <= 4096 && size.height <= 4096);
    assert!(scale > 0.01 && scale <= 2.0);
    assert!(doc_atlas_covers(origin, size, scale, tile));
}

#[test]
fn atlas_keeps_native_resolution_beyond_one_page() {
    // 15 × 10 visible cells: the old 4096 atlas shrank these to 313px.
    let view = Viewbox::new(14.0 * 512.0, 9.0 * 512.0);
    let tile_view = TileViewbox::new_with_interest(&view, 0);
    let mut cache = TileTextureCache::new(4096, 4096);
    cache.set_page_count(tiles::tile_atlas_page_count(150, 4096));
    fill_cache(&mut cache, &view);
    cache.update(&view, &tile_view);

    assert_eq!(cache.grid.len(), 150);
    assert_eq!(cache.batches.len(), 3);
    assert_eq!(
        cache
            .batches
            .iter()
            .map(|b| b.textures.len())
            .sum::<usize>(),
        150
    );
    let mut slots = HashSet::new();
    for reference in cache.grid.values() {
        assert_eq!(reference.rect.size(), skia::Size::new(512.0, 512.0));
        assert!(slots.insert((
            reference.page,
            reference.rect.left as i32,
            reference.rect.top as i32
        )));
    }
    for batch in &cache.batches {
        for transform in &batch.transforms {
            assert_eq!(transform.scos, 1.0);
            assert_eq!(transform.ssin, 0.0);
        }
    }
}

#[test]
fn atlas_growth_preserves_tiles_and_shrink_releases_only_trailing_pages() {
    let mut cache = TileTextureCache::new(1024, 1024);
    let small = Viewbox::new(512.0, 512.0);
    fill_cache(&mut cache, &small);
    let key = TileCacheKey::new(Tile(0, 0), 1.0);
    let original = cache.grid[&key].clone();
    cache.set_page_count(3);
    assert_eq!(cache.grid[&key].index, original.index);
    assert_eq!(cache.grid[&key].rect, original.rect);

    let large = Viewbox::new(4.0 * 512.0, 512.0);
    let tile_view = TileViewbox::new_with_interest(&large, 0);
    let mut docs = HashMap::new();
    for x in 2..5 {
        for y in 0..2 {
            cache.add(&tile_view, &Tile(x, y), 1.0, large.area, &mut docs);
        }
    }
    assert_eq!(cache.grid.len(), 10);
    cache.set_page_count(1);
    assert_eq!(cache.grid.len(), 4);
    assert_eq!(cache.provider.length, 4);
    assert!(cache.has(Tile(0, 0), 1.0));
    assert!(!cache.has(Tile(4, 1), 1.0));
    cache.set_page_count(3);
    let reference = cache.add(&tile_view, &Tile(4, 1), 1.0, large.area, &mut docs);
    assert_eq!(reference.page, 1);
    assert_eq!(cache.grid[&key].index, original.index);
}

#[test]
fn invalidation_and_gc_reuse_slots_without_evicting_visible_native_tiles() {
    let view = Viewbox::new(512.0, 512.0);
    let tile_view = TileViewbox::new_with_interest(&view, 0);
    let mut cache = TileTextureCache::new(1024, 1024);
    let mut docs = fill_cache(&mut cache, &view);
    for _ in 0..100 {
        cache.remove_at(Tile(0, 0), 1.0);
        assert!(!cache.has(Tile(0, 0), 1.0));
        cache.add(&tile_view, &Tile(0, 0), 1.0, view.area, &mut docs);
        assert!(cache.has(Tile(1, 1), 1.0));
        assert_eq!(cache.grid.len(), 4);
        assert_eq!(
            cache.provider.in_use.iter().filter(|used| **used).count(),
            4
        );
    }
    cache.clear();
    cache.update(&view, &tile_view);
    assert!(cache.batches.iter().all(|batch| batch.textures.is_empty()));
    cache.gc();
    assert!(cache.grid.is_empty());
    assert!(cache.removed.is_empty());
}

#[test]
fn hidpi_and_fractional_pan_compose_native_tiles_at_unit_scale_without_seams() {
    for dpr in [1.0, 1.25, 2.0, 3.0] {
        for zoom in [0.33, 1.0, 1.75] {
            let mut view = Viewbox::new(1024.0, 768.0);
            view.set_dpr(dpr);
            view.set_all(zoom, -103.5, 19.25);
            let tile_view = TileViewbox::new_with_interest(&view, 0);
            let mut cache = TileTextureCache::new(1024, 1024);
            cache.set_page_count(tiles::tile_atlas_page_count(
                tile_view.visible_rect.len() as usize,
                1024,
            ));
            let docs = fill_cache(&mut cache, &view);
            cache.update(&view, &tile_view);
            let preview = cache.build_atlas_draw_batch_for_doc_rects(&view, &tile_view, &docs);
            for (native, preview) in cache.batches.iter().zip(&preview[cache.batches.len()..]) {
                assert_eq!(native.textures, preview.textures);
                for (native, preview) in native.transforms.iter().zip(&preview.transforms) {
                    assert_eq!(native.scos, 1.0);
                    assert_eq!(preview.scos, 1.0);
                    assert_eq!(native.tx, preview.tx);
                    assert_eq!(native.ty, preview.ty);
                    assert_eq!(native.tx.fract(), 0.0);
                    assert_eq!(native.ty.fract(), 0.0);
                }
            }
        }
    }
}

fn pixels(surface: &mut skia::Surface, size: i32, origin: (i32, i32)) -> Vec<u8> {
    let info = skia::ImageInfo::new_n32_premul((size, size), None);
    let mut bytes = vec![0; size as usize * size as usize * 4];
    assert!(surface.read_pixels(&info, &mut bytes, size as usize * 4, origin));
    bytes
}

#[test]
fn paged_atlas_round_trip_preserves_text_and_single_pixel_graphics() {
    let mut source = skia::surfaces::raster_n32_premul((1024, 1024)).unwrap();
    let canvas = source.canvas();
    canvas.clear(skia::Color::WHITE);
    let mut paint = Paint::default();
    paint.set_color(skia::Color::BLACK);
    for x in (256..768).step_by(2) {
        canvas.draw_rect(Rect::from_xywh(x as f32, 256.0, 1.0, 64.0), &paint);
    }
    let manager = skia::FontMgr::custom_empty().unwrap();
    let face = manager
        .new_from_data(
            skia::Data::new_copy(include_bytes!("../fonts/sourcesanspro-regular.ttf")),
            None,
        )
        .unwrap();
    for (row, size) in [9.0, 12.0, 16.0, 24.0, 48.0].iter().enumerate() {
        let font = skia::Font::new(face.clone(), *size);
        canvas.draw_str(
            "Typography HIlm 0123 Grafik",
            (260.25, 350.5 + row as f32 * 65.0),
            &font,
            &paint,
        );
    }
    paint.set_anti_alias(true);
    canvas.draw_circle((690.5, 700.25), 38.25, &paint);
    let expected = pixels(&mut source, 512, (256, 256));

    // Small pages exercise page boundaries without a large test allocation.
    let mut provider = TileAtlasTextureProvider::new(1024, 1024, 512);
    provider.set_page_count(3);
    let mut pages: Vec<_> = (0..3)
        .map(|_| TileAtlasPage::new(skia::surfaces::raster_n32_premul((1024, 1024)).unwrap()))
        .collect();
    for _ in 0..10 {
        let reference = provider.allocate().unwrap();
        let page = &mut pages[reference.page];
        page.write_tile(&mut source, Rect::from(TILE_DRAWABLE_RECT), reference.rect);
        let mut batch = AtlasDrawBatch::default();
        batch.push(skia::RSXform::new(1.0, 0.0, (0.0, 0.0)), reference.rect);
        let mut output = skia::surfaces::raster_n32_premul((512, 512)).unwrap();
        page.draw(output.canvas(), &batch, skia::SamplingOptions::default());
        let actual = pixels(&mut output, 512, (0, 0));
        assert_eq!(
            actual.iter().zip(&expected).filter(|(a, b)| a != b).count(),
            0,
            "native atlas round trip changed pixels on page {}",
            reference.page
        );
    }
}

#[test]
fn atlas_snapshots_are_reused_until_their_page_changes() {
    let mut page = TileAtlasPage::new(skia::surfaces::raster_n32_premul((512, 512)).unwrap());
    let mut source = skia::surfaces::raster_n32_premul((512, 512)).unwrap();
    let mut output = skia::surfaces::raster_n32_premul((512, 512)).unwrap();
    let rect = Rect::from_wh(512.0, 512.0);
    source.canvas().clear(skia::Color::RED);
    page.write_tile(&mut source, rect, rect);
    let mut batch = AtlasDrawBatch::default();
    batch.push(skia::RSXform::new(1.0, 0.0, (0.0, 0.0)), rect);
    page.draw(output.canvas(), &batch, skia::SamplingOptions::default());
    let image_id = page.image.as_ref().unwrap().unique_id();
    page.draw(output.canvas(), &batch, skia::SamplingOptions::default());
    assert_eq!(page.image.as_ref().unwrap().unique_id(), image_id);
    // Reusing an occupied slot must replace old pixels, including alpha.
    source.canvas().clear(skia::Color::TRANSPARENT);
    page.write_tile(&mut source, rect, rect);
    assert!(page.image.is_none());
    output.canvas().clear(skia::Color::TRANSPARENT);
    page.draw(output.canvas(), &batch, skia::SamplingOptions::default());
    assert_eq!(
        pixels(&mut output, 512, (0, 0)),
        pixels(&mut source, 512, (0, 0))
    );
}

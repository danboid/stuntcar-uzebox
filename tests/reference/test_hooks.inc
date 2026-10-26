
/* test hook: the in-race crane reset, forced onto a given piece */
void dbg_force_reset(long piece)
{
	ResetPlayer();
	PositionCarAbovePiece(piece);
	drop_start_done = FALSE;
}

/* test hook: road height under a world x/z point */
long dbg_road_height(long x, long z)
{
	long h = 0x7fffffff;
	CalculateWorldRoadHeight(0, x, z, &h);
	return h;
}

/* test hook: wheel state */
void dbg_wheels(long *o)
{
	o[0] = front_left_road_height; o[1] = front_right_road_height; o[2] = rear_road_height;
	o[3] = front_left_actual_height; o[4] = front_right_actual_height; o[5] = rear_actual_height;
	o[6] = touching_road; o[7] = player_current_piece; o[8] = off_map_status; o[9] = off_track_count;
}

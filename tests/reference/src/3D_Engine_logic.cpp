/**************************************************************************

    3D Engine.cpp - Functions for producing 3D graphics

 **************************************************************************/

/*	============= */
/*	Include files */
/*	============= */
#include "dxstdafx.h"

#include "StuntCarRacer.h"
#include "3D_Engine.h"

/*	===== */
/*	Debug */
/*	===== */
#if defined(DEBUG) || defined(_DEBUG)
extern FILE *out;
extern long	VALUE1, VALUE2;
#endif

/*	========= */
/*	Constants */
/*	========= */
//#define	FALSE	0
//#define	TRUE	1

#define	SIN_COS_TABLE_SIZE	MAX_ANGLE + (MAX_ANGLE/4)	// makes use of sine/cosine overlap

/*	=========== */
/*	Global data */
/*	=========== */
extern DWORD Fill_Colour, Line_Colour;

/*	=========== */
/*	Static data */
/*	=========== */
static short Sin_Cos[SIN_COS_TABLE_SIZE];

short Trig_Coeffs2[NUM_TRIG_COEFFS];
static short Trig_Coeffs[NUM_TRIG_COEFFS];
static long World_X_Offset, World_Y_Offset, World_Z_Offset;

/*	The location of transformed co-ordinates can now be changed - for DrawZClippedPiece */
static COORD_3D Default_Transformed_Coords[MAX_COORDS];
static COORD_3D *Transformed_Coords = Default_Transformed_Coords;

/*	The location of screen co-ordinates can now be changed - for DrawPiece */
static COORD_2D Default_Screen_Coords[MAX_COORDS];	// could use POINT structure
static COORD_2D *Screen_Coords = Default_Screen_Coords;

#ifdef NOT_USED
long TEMPZ[MAX_POLY_SIDES];
#endif

/*	===================== */
/*	Function declarations */
/*	===================== */
static long LockAngle( long opposite,
					   long adjacent,
					   long clockwise );

/*	======================================================================================= */
/*	Function:		CreateSinCosTable														*/
/*																							*/
/*	Description:	Calculate and store sine/cosine values needed for 3D rotation			*/
/*	======================================================================================= */

void CreateSinCosTable( void )
	{
	long i;
	double angle, step, value;

	angle = 0;
	step = (static_cast<double>(2) * static_cast<double>(PI)) / static_cast<double>(MAX_ANGLE);
	for ( i = 0; i < SIN_COS_TABLE_SIZE; i++ )
		{
		value = sin( angle );
		value = value * static_cast<double>(PRECISION);

		Sin_Cos[i] = (short)value;
		angle += step;
		}
	}

/*	======================================================================================= */
/*	Function:		GetSinCos																*/
/*																							*/
/*	Description:	Provide sine/cosine of supplied angle									*/
/*	======================================================================================= */

void GetSinCos( long angle,
				short *sin,
				short *cos )
	{
	*sin = Sin_Cos[angle];
	*cos = Sin_Cos[angle + (MAX_ANGLE/4)];
	}

#ifdef NOT_USED
/*	======================================================================================= */
/*	Function:		SetWorldOffset															*/
/*																							*/
/*	Description:	Set World X, Y and Z offsets needed for 3D transformation				*/
/*	======================================================================================= */

void SetWorldOffset( long x_offset,
					 long y_offset,
					 long z_offset )
	{
	World_X_Offset = x_offset;
	World_Y_Offset = y_offset;
	World_Z_Offset = z_offset;
	}

/*	======================================================================================= */
/*	Function:		SetCoords																*/
/*																							*/
/*	Description:	Set the locations to be used for subsequent graphic operations			*/
/*	======================================================================================= */

void SetCoords( COORD_3D *tptr,
				COORD_2D *sptr )
	{
	Transformed_Coords = tptr;
	Screen_Coords = sptr;
	}

/*	======================================================================================= */
/*	Function:		DefaultCoords															*/
/*																							*/
/*	Description:	Default the locations to be used for subsequent graphic operations		*/
/*	======================================================================================= */

void DefaultCoords( void )
	{
	Transformed_Coords = Default_Transformed_Coords;
	Screen_Coords = Default_Screen_Coords;
	}
#endif
/*	======================================================================================= */
/*	Function:		CalcYXZTrigCoefficients													*/
/*																							*/
/*	Description:	Calculate all coefficients needed for 3D rotation in order Y, X, Z		*/
/*																							*/
/*					NOTE: Uses '3D Maths' rotations :-										*/
/*							Y-Rotation - Anti-clockwise										*/
/*							X-Rotation - Anti-Clockwise										*/
/*							Z-Rotation - Anti-Clockwise										*/
/*	======================================================================================= */

void CalcYXZTrigCoefficients( long x_angle,
							  long y_angle,
							  long z_angle )
	{
	short sin_x, sin_y, sin_z;
	short cos_x, cos_y, cos_z;

	/*	========================= */
	/*	Get sine/cosine of angles */
	/*	========================= */
	sin_x = Sin_Cos[x_angle];
	sin_y = Sin_Cos[y_angle];
	sin_z = Sin_Cos[z_angle];

	cos_x = Sin_Cos[x_angle + (MAX_ANGLE/4)];
	cos_y = Sin_Cos[y_angle + (MAX_ANGLE/4)];
	cos_z = Sin_Cos[z_angle + (MAX_ANGLE/4)];

	/*	================================ */
	/*	Calculate rotated x coefficients */
	/*	================================ */
	/*
	Trig_Coeffs[X_X_COMP] = ((cos_y * cos_z) - (((sin_x * sin_y) / PRECISION) * sin_z)) / PRECISION;
	Trig_Coeffs[X_Y_COMP] = -(cos_x * sin_z) / PRECISION;
	Trig_Coeffs[X_Z_COMP] = ((sin_y * cos_z) + (((sin_x * cos_y) / PRECISION) * sin_z)) / PRECISION;
	*/
	Trig_Coeffs[X_X_COMP] = (short)(((cos_y * cos_z) + (((sin_x * sin_y) / PRECISION) * sin_z)) / PRECISION);
	Trig_Coeffs[X_Y_COMP] = (short)(-(cos_x * sin_z) / PRECISION);
	Trig_Coeffs[X_Z_COMP] = (short)((-(sin_y * cos_z) + (((sin_x * cos_y) / PRECISION) * sin_z)) / PRECISION);

	/*	================================ */
	/*	Calculate rotated y coefficients */
	/*	================================ */
	/*
	Trig_Coeffs[Y_X_COMP] = ((cos_y * sin_z) + (((sin_x * sin_y) / PRECISION) * cos_z)) / PRECISION;
	Trig_Coeffs[Y_Y_COMP] = (cos_x * cos_z) / PRECISION;
	Trig_Coeffs[Y_Z_COMP] = ((sin_y * sin_z) - (((sin_x * cos_y) / PRECISION) * cos_z)) / PRECISION;
	*/
	Trig_Coeffs[Y_X_COMP] = (short)(((cos_y * sin_z) - (((sin_x * sin_y) / PRECISION) * cos_z)) / PRECISION);
	Trig_Coeffs[Y_Y_COMP] = (short)((cos_x * cos_z) / PRECISION);
	Trig_Coeffs[Y_Z_COMP] = (short)((-(sin_y * sin_z) - (((sin_x * cos_y) / PRECISION) * cos_z)) / PRECISION);

	/*	================================ */
	/*	Calculate rotated z coefficients */
	/*	================================ */
	/*
	Trig_Coeffs[Z_X_COMP] = -(cos_x * sin_y) / PRECISION;
	Trig_Coeffs[Z_Y_COMP] = sin_x;
	Trig_Coeffs[Z_Z_COMP] = (cos_x * cos_y) / PRECISION;
	*/
	Trig_Coeffs[Z_X_COMP] = (short)((cos_x * sin_y) / PRECISION);
	Trig_Coeffs[Z_Y_COMP] = sin_x;
	Trig_Coeffs[Z_Z_COMP] = (short)((cos_x * cos_y) / PRECISION);
	}

/*	======================================================================================= */
/*	Function:		TrigCoefficients														*/
/*																							*/
/*	Description:	Return ptr. to coefficients needed for 3D rotation						*/
/*	======================================================================================= */

short *TrigCoefficients( void )
	{
	return(Trig_Coeffs);
	}

/*	======================================================================================= */
/*	Function:		RotateCoordinate														*/
/*																							*/
/*	Description:	Perform 3D rotation on supplied co-ordinate								*/
/*	======================================================================================= */
#ifdef NOT_USED
void RotateCoordinate( long *xptr,
					   long *yptr,
					   long *zptr )
	{
	long x, y, z;

	x = *xptr;
	y = *yptr;
	z = *zptr;

	*xptr = (x * static_cast<long>(Trig_Coeffs[X_X_COMP])) +
			(y * static_cast<long>(Trig_Coeffs[X_Y_COMP])) +
			(z * static_cast<long>(Trig_Coeffs[X_Z_COMP]));

	*yptr = (x * static_cast<long>(Trig_Coeffs[Y_X_COMP])) +
			(y * static_cast<long>(Trig_Coeffs[Y_Y_COMP])) +
			(z * static_cast<long>(Trig_Coeffs[Y_Z_COMP]));

	*zptr = (x * static_cast<long>(Trig_Coeffs[Z_X_COMP])) +
			(y * static_cast<long>(Trig_Coeffs[Z_Y_COMP])) +
			(z * static_cast<long>(Trig_Coeffs[Z_Z_COMP]));
	}
#endif
/*	======================================================================================= */
/*	Function:		WorldOffset (opposite of RotateCoordinate)								*/
/*																							*/
/*	Description:	Takes the input vector and provides the World vector					*/
/*					for the given rotation (i.e. sums X/Y/Z components)						*/
/*	======================================================================================= */

void WorldOffset( long *xptr,
				  long *yptr,
				  long *zptr )
	{
	long x, y, z;

	x = *xptr;
	y = *yptr;
	z = *zptr;

	*xptr = (x * static_cast<long>(Trig_Coeffs[X_X_COMP])) +
			(y * static_cast<long>(Trig_Coeffs[Y_X_COMP])) +
			(z * static_cast<long>(Trig_Coeffs[Z_X_COMP]));

	*yptr = (x * static_cast<long>(Trig_Coeffs[X_Y_COMP])) +
			(y * static_cast<long>(Trig_Coeffs[Y_Y_COMP])) +
			(z * static_cast<long>(Trig_Coeffs[Z_Y_COMP]));

	*zptr = (x * static_cast<long>(Trig_Coeffs[X_Z_COMP])) +
			(y * static_cast<long>(Trig_Coeffs[Y_Z_COMP])) +
			(z * static_cast<long>(Trig_Coeffs[Z_Z_COMP]));
	}

/*	======================================================================================= */
/*	Function:		TransformCoordinates													*/
/*																							*/
/*	Description:	Perform 3D rotation and translation on required co-ordinates			*/
/*	======================================================================================= */
#ifdef NOT_USED
long TransformCoordinates( COORD_3D *cptr,
						   long size )
	{
	long i, number;
	long x, y, z;
	long trans_x, trans_y, trans_z;
	long screen_width, screen_height;

	// calculate number of co-ordinates
	number = size / sizeof(COORD_3D);

	// finish if too many co-ordinates
	if (number > MAX_COORDS)
		return(FALSE);

	GetScreenDimensions(&screen_width, &screen_height);

	// transform each co-ordinate in turn
	for (i = 0; i < number; i++)
		{
		x = cptr->x;
		y = cptr->y;
		z = cptr->z;
		cptr++;

		// rotate current co-ordinate
		trans_x = (x * static_cast<long>(Trig_Coeffs[X_X_COMP])) +
				  (y * static_cast<long>(Trig_Coeffs[X_Y_COMP])) +
				  (z * static_cast<long>(Trig_Coeffs[X_Z_COMP]));

		trans_y = (x * static_cast<long>(Trig_Coeffs[Y_X_COMP])) +
				  (y * static_cast<long>(Trig_Coeffs[Y_Y_COMP])) +
				  (z * static_cast<long>(Trig_Coeffs[Y_Z_COMP]));

		trans_z = (x * static_cast<long>(Trig_Coeffs[Z_X_COMP])) +
				  (y * static_cast<long>(Trig_Coeffs[Z_Y_COMP])) +
				  (z * static_cast<long>(Trig_Coeffs[Z_Z_COMP]));

		// add world offsets
		trans_x += World_X_Offset;
		trans_y += World_Y_Offset;
		trans_z += World_Z_Offset;

		// finish if any z negative (i.e. infront of screen)
		if (trans_z <= 0)
			return(FALSE);

		// store world x, world y and world z
		Transformed_Coords[i].x = trans_x;
		Transformed_Coords[i].y = trans_y;
		Transformed_Coords[i].z = trans_z;

		// perspective projection
		z = trans_z >> LOG_FOCUS;

		// debug stuff
		if (z == 0)
			{
#if defined(DEBUG) || defined(_DEBUG)
			fprintf(out, "5.  Preventing division by zero\n");
			//Sleep(10);
#endif

			z = 1;
			}

		x = (trans_x / z) + screen_width/2;
		y = (trans_y / z) + screen_height/2;

		// store screen x and screen y
		Screen_Coords[i].x = x;
		Screen_Coords[i].y = y;
		}

	return(TRUE);
	}

/*	======================================================================================= */
/*	Function:		TransformedZ															*/
/*																							*/
/*	Description:	Return required transformed z co-ordinate								*/
/*	======================================================================================= */

long TransformedZ( long offset )
	{
	return(Transformed_Coords[offset].z);
	}

/*	======================================================================================= */
/*	Function:		TexturedPolygon															*/
/*																							*/
/*	Description:	Set the origin and u,v vectors needed for texture mapping				*/
/*					Use the Polygon function to draw the polygon							*/
/*	======================================================================================= */

#endif
/*	======================================================================================= */
/*	Function:		LockViewpointToTarget													*/
/*																							*/
/*	Description:	Calculate x/y angles required to place target within centre of view     */
/*	======================================================================================= */

void LockViewpointToTarget( long viewpoint_x,
							long viewpoint_y,
							long viewpoint_z,
							long target_x,
							long target_y,
							long target_z,
							long *viewpoint_x_angle,
							long *viewpoint_y_angle )
	{
	long opp, adj;
	double a, b, h;

	// y angle
	opp = target_x - viewpoint_x;
	adj = target_z - viewpoint_z;
	*viewpoint_y_angle = LockAngle(opp, adj, FALSE);

	// x angle
	a = static_cast<double>((target_x - viewpoint_x) >> LOG_PRECISION);
	b = static_cast<double>((target_z - viewpoint_z) >> LOG_PRECISION);
	h = sqrt((a*a) + (b*b));
	adj = static_cast<long>(h * PRECISION);
	opp = target_y - viewpoint_y;
	*viewpoint_x_angle = LockAngle(opp, adj, FALSE);

	return;
	}


static long LockAngle( long opposite,
					   long adjacent,
					   long clockwise )
	{
	long viewpoint_angle;
	double o, a, radians, angle;

	o = static_cast<double>(opposite);
	a = static_cast<double>(adjacent);

	// use inverse tan to calculate basic angle in radians
	if (a == 0)		// prevent division by zero
		radians = static_cast<double>(PI) / static_cast<double>(2);	// 90 degrees
	else
		radians = atan(o/a);	// inverse tan

	// convert radians to internal angle (also round up)
	angle = ((radians * static_cast<double>(MAX_ANGLE)) / (static_cast<double>(2) * static_cast<double>(PI)));
	// convert to absolute and round up as follows (because abs() isn't for doubles)
	if (angle > 0)
		viewpoint_angle = static_cast<long>(angle + static_cast<double>(0.5));
	else
		viewpoint_angle = static_cast<long>(static_cast<double>(0.5) - angle);

	// convert angle from first quadrant to full range
	if (o >= 0)
		{
		if (a >= 0)
			{
			// first quadrant
			viewpoint_angle = static_cast<long>(angle);
			}
		else
			{
			// second quadrant
			viewpoint_angle = static_cast<long>(angle) + _180_DEGREES;
			}
		}
	else
		{
		if (a <= 0)
			{
			// third quadrant
			viewpoint_angle = static_cast<long>(angle) + _180_DEGREES;
			}
		else
			{
			// fourth quadrant
			viewpoint_angle = static_cast<long>(angle) + _360_DEGREES;
			}
		}

	// default is anti-clockwise, so convert to clockwise if necessary
	if (clockwise)
		{
		viewpoint_angle = (-viewpoint_angle) & (MAX_ANGLE-1);
		}

	return(viewpoint_angle);
	}


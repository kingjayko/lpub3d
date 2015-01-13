/**************************************************************************** 
**
** Copyright (C) 2007-2009 Kevin Clague. All rights reserved.
**
** This file may be used under the terms of the GNU General Public
** License version 2.0 as published by the Free Software Foundation
** and appearing in the file LICENSE.GPL included in the packaging of
** this file.  Please review the following information to ensure GNU
** General Public Licensing requirements will be met:
** http://www.trolltech.com/products/qt/opensource.html
**
** This file is provided AS IS with NO WARRANTY OF ANY KIND, INCLUDING THE
** WARRANTY OF DESIGN, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.
**
****************************************************************************/
#ifndef LPUB_PREFERENCES_H
#define LPUB_PREFERENCES_H

// Version number.
#define LP_VERSION_MAJOR 4
#define LP_VERSION_MINOR 10
#define LP_VERSION_PATCH 0
#define LP_VERSION_TEXT "4.10.0"
#define LP_VERSION_EMAIL "mailto:trevor.sandy@gmail.com?subject=LPub"


class QString;

class Preferences
{

  public:
    Preferences();
    static void lpubPreferences();
    static void ldrawPreferences(bool);
	static void lgeoPreferences();
    static void renderPreferences();
    static void pliPreferences();
    static void unitsPreferences();
    static void annotationPreferences();
    static void fadestepPreferences();
    static void getRequireds();
    static bool getPreferences();

    static QString ldrawPath;
    static QString lgeoPath;
    static QString ldgliteExe;
    static QString ldviewExe;
	static QString l3pExe;
	static QString povrayExe;
    static QString preferredRenderer;
    static QString pliFile;
    static QString lpubPath;
    static QString fadeStepColor;
    static bool    preferCentimeters;
    static bool    preferTitleAnnotation;
    static bool    enableFadeStep;

    virtual ~Preferences() {}
};

#endif

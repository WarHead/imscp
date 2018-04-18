<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 * Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

use iMSCP\TemplateEngine;
use iMSCP_Events as Events;
use iMSCP_Exception as iMSCPException;
use iMSCP_Registry as Registry;
use Zend_Navigation as Navigation;

// Common

/**
 * Generate logged from block
 *
 * @param TemplateEngine $tpl
 * @return void
 */
function generateLoggedFrom(TemplateEngine $tpl)
{
    $tpl->define('logged_from', 'layout');

    if (!isset($_SESSION['logged_from']) || !isset($_SESSION['logged_from_id'])) {
        $tpl->assign('LOGGED_FROM', '');
        return;
    }

    $tpl->assign([
        'YOU_ARE_LOGGED_AS' => tr('%1$s you are now logged as %2$s', $_SESSION['logged_from'], $_SESSION['user_logged']),
        'TR_GO_BACK'        => tr('Back')
    ]);
    $tpl->parse('LOGGED_FROM', 'logged_from');
}

/**
 * Generates list of available languages
 *
 * @param  TemplateEngine $tpl
 * @param  string $selectedLanguage Selected language
 * @return void
 */
function generateLanguagesList(TemplateEngine $tpl, $selectedLanguage)
{
    foreach (getAvailableLanguages() as $language) {
        $tpl->assign([
            'LANG_VALUE'    => toHtml($language['locale'], 'htmlAttr'),
            'LANG_SELECTED' => ($language['locale'] == $selectedLanguage) ? ' selected' : '',
            'LANG_NAME'     => toHtml($language['language'])
        ]);
        $tpl->parse('DEF_LANGUAGE', '.def_language');
    }
}

/**
 * Generate lists for days, months and years
 *
 * @param TemplateEngine $tpl
 * @param int $day Selected day
 * @param int $month Selected month (date(
 * @param int $year Selected year (4 digits expected)
 * @param int $nPastYears Number of past years to display in years select list
 * @return void
 */
function generateDMYlists(TemplateEngine $tpl, $day, $month, $year, $nPastYears)
{
    if (!in_array($month, range(1, 12))) {
        $month = date('n');
    }

    if ($tpl->isTemplateVariable('day_list')) {
        $nDays = date('t', mktime(0, 0, 0, $month, 1, $year));

        // 0 = all days
        if (!in_array($day, range(0, $nDays))) {
            $day = 0;
        }

        foreach (range(0, $nDays) as $lday) {
            $tpl->assign([
                'OPTION_SELECTED' => $lday == $day ? ' selected' : '',
                'VALUE'           => toHtml($lday, 'htmlAttr'),
                'HUMAN_VALUE'     => $lday == 0 ? toHtml(tr('All')) : toHtml($lday)
            ]);
            $tpl->parse('DAY_LIST', '.day_list');
        }
    }

    foreach (range(1, 12) as $lmonth) {
        $tpl->assign([
            'OPTION_SELECTED' => $lmonth == $month ? ' selected' : '',
            'MONTH_VALUE'     => toHtml($lmonth)
        ]);
        $tpl->parse('MONTH_LIST', '.month_list');
    }

    $curYear = date('Y');

    foreach (range($curYear - $nPastYears, $curYear) as $lyear) {
        $tpl->assign([
            'OPTION_SELECTED' => $lyear == $year ? ' selected' : '',
            'YEAR_VALUE'      => toHtml($lyear, 'htmlAttr'),
        ]);
        $tpl->parse('YEAR_LIST', '.year_list');
    }
}

/**
 * Generate navigation
 *
 * @throws iMSCPException
 * @param TemplateEngine $tpl
 * @return void
 */
function generateNavigation(TemplateEngine $tpl)
{
    Registry::get('iMSCP_Application')->getEventsManager()->dispatch(Events::onBeforeGenerateNavigation, ['templateEngine' => $tpl]);

    $tpl->define([
        'main_menu_block'       => 'layout',
        'main_menu_link_block'  => 'main_menu_block',
        'left_menu_block'       => 'layout',
        'left_menu_link_block'  => 'left_menu_block',
        'breadcrumb_block'      => 'layout',
        'breadcrumb_link_block' => 'breadcrumb_block'
    ]);

    generateLoggedFrom($tpl);

    /** @var $navigation Navigation */
    $navigation = Registry::get('navigation');

    // Dynamic links (only at customer level)
    if ($_SESSION['user_type'] == 'user') {
        $domainProperties = getCustomerProperties($_SESSION['user_id']);
        $tpl->assign('WEBSTATS_PATH', 'http://' . decodeIdna($domainProperties['domain_name']) . '/stats/');

        if (customerHasFeature('mail')) {
            $webmails = getWebmailList();

            if (!empty($webmails)) {
                $page1 = $navigation->findOneBy('class', 'email');
                $page2 = $navigation->findOneBy('class', 'webtools');

                foreach ($webmails as $webmail) {
                    $page = [
                        'label'  => toHtml($webmail),
                        'uri'    => '/' . ($webmail == 'Roundcube' ? 'webmail' : strtolower($webmail)) . '/',
                        'target' => '_blank',
                    ];
                    $page1->addPage($page);
                    $page2->addPage($page);
                }
            }
        }

        if (customerHasFeature('ftp')) {
            $filemanagers = getFilemanagerList();
            if (!empty($filemanagers)) {
                $page1 = $navigation->findOneBy('class', 'ftp');
                $page2 = $navigation->findOneBy('class', 'webtools');

                foreach ($filemanagers as $filemanager) {
                    $page = [
                        'label'  => toHtml($filemanager),
                        'uri'    => '/' . ($filemanager == 'MonstaFTP' ? 'ftp' : strtolower($filemanager)) . '/',
                        'target' => '_blank',
                    ];
                    $page1->addPage($page);
                    $page2->addPage($page);
                }
            }
        }
    }

    $cfg = Registry::get('iMSCP_Application')->getConfig();

    // Remove support system page if feature is globally disabled
    if (!$cfg['IMSCP_SUPPORT_SYSTEM']) {
        $navigation->removePage($navigation->findOneBy('class', 'support'));
    } else {
        // Dynamic links (All levels)
        $tpl->assign([
            'SUPPORT_SYSTEM_PATH'   => 'ticket_system.php',
            'SUPPORT_SYSTEM_TARGET' => '_self'
        ]);
    }

    // Custom menus
    if (NULL !== $customMenus = getCustomMenus($_SESSION['user_type'])) {
        foreach ($customMenus as $customMenu) {
            $navigation->addPage([
                'order'  => $customMenu['menu_order'],
                'label'  => toHtml($customMenu['menu_name']),
                'uri'    => getMenuVariables($customMenu['menu_link']),
                'target' => !empty($customMenu['menu_target']) ? toHtml($customMenu['menu_target']) : '_self',
                'class'  => 'custom_link'
            ]);
        }
    }

    /** @var $activePage Zend_Navigation_Page_Uri */
    foreach ($navigation->findAllBy('uri', $_SERVER['SCRIPT_NAME']) as $activePage) {
        $activePage->setActive();
    }

    $query = !empty($_GET) ? '?' . http_build_query($_GET) : '';

    /** @var $page Zend_Navigation_Page */
    foreach ($navigation as $page) {
        if (NULL !== $callbacks = $page->get('privilege_callback')) {
            $callbacks = isset($callbacks['name']) ? [$callbacks] : $callbacks;
            foreach ($callbacks as $callback) {
                if (!call_user_func_array($callback['name'], isset($callback['param']) ? (array)$callback['param'] : [])) {
                    continue 2;
                }
            }
        }

        if (!$page->isVisible()) {
            continue;
        }

        $tpl->assign([
            'HREF'                    => $page->getHref(),
            'CLASS'                   => $page->getClass() . ($_SESSION['show_main_menu_labels'] ? ' show_labels' : ''),
            'IS_ACTIVE_CLASS'         => $page->isActive(true) ? 'active' : 'dummy',
            'TARGET'                  => $page->getTarget() ? toHtml($page->getTarget()) : '_self',
            'MAIN_MENU_LABEL_TOOLTIP' => toHtml($page->getLabel(), 'htmlAttr'),
            'MAIN_MENU_LABEL'         => $_SESSION['show_main_menu_labels'] ? toHtml($page->getLabel()) : ''
        ]);

        // Add page to main menu
        $tpl->parse('MAIN_MENU_LINK_BLOCK', '.main_menu_link_block');

        if (!$page->isActive(true)) {
            continue;
        }

        $tpl->assign([
            'TR_SECTION_TITLE'    => toHtml($page->getLabel()),
            'SECTION_TITLE_CLASS' => $page->getClass()
        ]);

        // Add page to breadcrumb
        $tpl->assign('BREADCRUMB_LABEL', toHtml($page->getLabel()));
        $tpl->parse('BREADCRUMB_LINK_BLOCK', '.breadcrumb_link_block');

        if (!$page->hasPages()) { // Should never occurs but...
            $tpl->assign([
                'LEFT_MENU_BLOCK'  => '',
                'BREADCRUMB_BLOCK' => ''
            ]);
            continue;
        }

        $page = new RecursiveIteratorIterator($page, RecursiveIteratorIterator::SELF_FIRST);
        foreach ($page as $subpage) {
            if (NULL !== $callbacks = $subpage->get('privilege_callback')) {
                $callbacks = isset($callbacks['name']) ? [$callbacks] : $callbacks;
                foreach ($callbacks AS $callback) {
                    if (!call_user_func_array($callback['name'], isset($callback['param']) ? (array)$callback['param'] : [])) {
                        continue 2;
                    }
                }
            }

            $tpl->assign([
                'HREF'            => $subpage->getHref(),
                'IS_ACTIVE_CLASS' => $subpage->isActive(true) ? 'active' : 'dummy',
                'LEFT_MENU_LABEL' => toHtml($subpage->getLabel()),
                'TARGET'          => $subpage->getTarget() ?: '_self'
            ]);

            if ($subpage->isVisible()) {
                $tpl->parse('LEFT_MENU_LINK_BLOCK', '.left_menu_link_block'); // Add subpage to left menu
            }

            if (!$subpage->isActive(true)) {
                continue;
            }

            $tpl->assign([
                'TR_TITLE'    => $subpage->get('dynamic_title') ? $subpage->get('dynamic_title') : toHtml($subpage->getLabel()),
                'TITLE_CLASS' => $subpage->get('title_class')
            ]);

            if (!$subpage->hasPages()) {
                $tpl->assign('HREF', $subpage->getHref() . $query);
            }

            // add subpage to breadcrumbs
            $tpl->assign('BREADCRUMB_LABEL', toHtml($subpage->get('dynamic_title') ?: $subpage->getLabel()));
            $tpl->parse('BREADCRUMB_LINK_BLOCK', '.breadcrumb_link_block');
        }
    }

    // Static variables
    $tpl->assign([
        'TR_MENU_LOGOUT' => toHtml(tr('Logout')),
        'VERSION'        => !empty($cfg['Version']) ? $cfg['Version'] : toHtml(tr('Unknown')),
        'BUILDDATE'      => !empty($cfg['BuildDate']) ? $cfg['BuildDate'] : toHtml(tr('Unreleased')),
        'CODENAME'       => !empty($cfg['CodeName']) ? $cfg['CodeName'] : toHtml(tr('Unknown'))
    ]);

    Registry::get('iMSCP_Application')->getEventsManager()->dispatch(Events::onAfterGenerateNavigation, ['templateEngine' => $tpl]);
}

/**
 * Get custom menus for the given user
 *
 * @throws iMSCPException
 * @param string $userLevel User type (admin, reseller or user)
 * @return null|[] Array containing custom menus definitions or NULL in case no
 *                 custom menu is found
 */
function getCustomMenus($userLevel)
{
    if ($userLevel == 'admin') {
        $param = 'A';
    } elseif ($userLevel == 'reseller') {
        $param = 'R';
    } elseif ($userLevel == 'user') {
        $param = 'C';
    } else {
        throw new iMSCPException("Unknown user level '$userLevel' for getCustomMenus() function.");
    }

    $stmt = execQuery('SELECT * FROM custom_menus WHERE menu_level LIKE ?', ["%$param%"]);
    if ($stmt->rowCount()) {
        return $stmt->fetchAll();
    }

    return NULL;
}

// Admin

/**
 * Generate administrators list
 *
 * @param  TemplateEngine $tpl
 * @return void
 */
function generateAdministratorsList(TemplateEngine $tpl)
{
    $stmt = executeQuery(
        "
          SELECT t1.admin_id, t1.admin_name, t1.domain_created, t2.admin_name AS created_by
          FROM admin AS t1
          LEFT JOIN admin AS t2 ON (t1.created_by = t2.admin_id)
          WHERE t1.admin_type = 'admin'
          ORDER BY t1.admin_name ASC
        "
    );

    if (!$stmt->rowCount()) {
        $tpl->assign('ADMINISTRATOR_LIST', '');
        return;
    }

    $tpl->assign('ADMINISTRATOR_MESSAGE', '');
    $cfg = Registry::get('config');

    while ($row = $stmt->fetch()) {
        $tpl->assign([
            'ADMINISTRATOR_USERNAME'   => toHtml($row['admin_name']),
            'ADMINISTRATOR_CREATED_ON' => toHtml($row['domain_created'] == 0 ? tr('N/A') : date($cfg['DATE_FORMAT'], $row['domain_created'])),
            'ADMINISTRATPR_CREATED_BY' => toHtml(is_null($row['created_by']) ? tr('System') : $row['created_by']),
            'ADMINISTRATOR_ID'         => $row['admin_id']
        ]);

        if (is_null($row['created_by']) || $row['admin_id'] == $_SESSION['user_id']) {
            $tpl->assign('ADMINISTRATOR_DELETE_LINK', '');
        } else {
            $tpl->parse('ADMINISTRATOR_DELETE_LINK', 'administrator_delete_link');
        }

        $tpl->parse('ADMINISTRATOR_ITEM', '.administrator_item');
    }
}

/**
 * Generate reseller list
 *
 * @param  TemplateEngine $tpl
 * @return void
 */
function generateResellersList(TemplateEngine $tpl)
{
    $stmt = executeQuery(
        "
          SELECT t1.admin_id, t1.admin_name, t1.domain_created, t2.admin_name AS created_by
          FROM admin AS t1
          LEFT JOIN admin AS t2 ON (t1.created_by = t2.admin_id)
          WHERE t1.admin_type = 'reseller'
          ORDER BY t1.admin_name ASC
        "
    );

    if (!$stmt->rowCount()) {
        $tpl->assign('RESELLER_LIST', '');
        return;
    }

    $tpl->assign('RESELLER_MESSAGE', '');
    $cfg = Registry::get('config');

    while ($row = $stmt->fetch()) {
        $tpl->assign([
            'RESELLER_USERNAME'   => toHtml($row['admin_name']),
            'RESELLER_CREATED_ON' => toHtml($row['domain_created'] == 0 ? tr('N/A') : date($cfg['DATE_FORMAT'], $row['domain_created'])),
            'RESELLER_CREATED_BY' => toHtml(is_null($row['created_by']) ? tr('Unknown') : $row['created_by']),
            'RESELLER_ID'         => $row['admin_id']
        ]);
        $tpl->parse('RESELLER_ITEM', '.reseller_item');
    }
}

// Admin/reseller

/**
 * Get count and search queries for users search
 *
 * @param int $sLimit Start limit
 * @param int $eLimit End limit
 * @param string|null $searchField Field to search
 * @param string|null $searchValue Value to search
 * @param string|null $searchStatus Status to search
 * @return array Array containing count and search queries
 */
function getSearchUserQueries($sLimit, $eLimit, $searchField = NULL, $searchValue = NULL, $searchStatus = NULL)
{
    $sLimit = intval($sLimit);
    $eLimit = intval($eLimit);
    $where = '';

    if ($_SESSION['user_type'] == 'reseller') {
        $where .= 'WHERE t2.created_by = ' . intval($_SESSION['user_id']);
    }

    if ($searchStatus !== NULL && $searchStatus != 'anything') {
        $where .= ($where == '' ? 'WHERE ' : ' AND ') . 't1.domain_status' . (
            $searchStatus == 'ok' || $searchStatus == 'disabled'
                ? ' = ' . quoteValue($searchStatus)
                : " NOT IN ('ok', 'disabled', 'toadd', 'tochange', 'toenable', 'torestore', 'todisable', 'todelete')"
            );
    }

    if ($searchField !== NULL && $searchField != 'anything') {
        if ($searchField == 'domain_name') {
            $where .= ($where == '' ? 'WHERE ' : ' AND ') . 't1.domain_name';
        } elseif ($_SESSION['user_type'] == 'admin' && $searchField == 'reseller_name') {
            $where .= ($where == '' ? 'WHERE ' : ' AND ') . 't3.admin_name';
        } elseif (in_array($searchField, ['fname', 'lname', 'firm', 'city', 'state', 'country'], true)) {
            $where .= ($where == '' ? 'WHERE ' : ' AND ') . "t2.$searchField";
        } else {
            showBadRequestErrorPage();
        }

        $searchValue = str_replace(['!', '_', '%'], ['!!!', '!_', '!%'], $searchValue);
        $where .= ' LIKE ' . quoteValue('%' . ($searchField == 'domain_name' ? encodeIdna($searchValue) : $searchValue) . '%') . " ESCAPE '!'";
    }

    return [
        "
            SELECT COUNT(t1.domain_id)
            FROM domain AS t1
            JOIN admin AS t2 ON(t2.admin_id = t1.domain_admin_id)
            JOIN admin AS t3 ON(t3.admin_id = t2.created_by)
            $where
        ",
        "
            SELECT t1.domain_id, t1.domain_name, t1.domain_created, t1.domain_expires, t1.domain_status, t1.domain_disk_limit,
                t1.domain_disk_usage, t2.admin_id, t2.admin_status, t3.admin_name AS reseller_name
            FROM domain AS t1
            JOIN admin AS t2 ON(t2.admin_id = t1.domain_admin_id)
            JOIN admin AS t3 ON(t3.admin_id = t2.created_by)
            $where
            ORDER BY t1.domain_name ASC
            LIMIT $sLimit, $eLimit
        "
    ];
}

/**
 * Generate user search fields
 *
 * @param TemplateEngine $tpl
 * @param string|null $searchField Field to search
 * @param string|null $searchValue Value to search
 * @param string|null $searchStatus Status to search
 * @return void
 */
function generateSearchUserFields(TemplateEngine $tpl, $searchField = NULL, $searchValue = NULL, $searchStatus = NULL)
{
    $none = $domain = $customerId = $firstname = $lastname = $company = $city = $state = $country = $resellerName =
    $anything = $ok = $suspended = $error = '';

    if ($searchField === NULL && $searchValue === NULL && $searchStatus === NULL) {
        $none = $anything = ' selected';
        $tpl->assign('SEARCH_VALUE', '');
    } else {
        if ($searchField == NULL || $searchField == 'anything') {
            $none = ' selected';
        } elseif ($searchField == 'domain_name') {
            $domain = ' selected';
        } elseif ($searchField == 'fname') {
            $firstname = ' selected';
        } elseif ($searchField == 'lname') {
            $lastname = ' selected';
        } elseif ($searchField == 'firm') {
            $company = ' selected';
        } elseif ($searchField == 'city') {
            $city = ' selected';
        } elseif ($searchField == 'state') {
            $state = ' selected';
        } elseif ($searchField == 'country') {
            $country = ' selected';
        } elseif ($_SESSION['user_type'] == 'admin' && $searchField == 'reseller_name') {
            $resellerName = ' selected';
        } else {
            showBadRequestErrorPage();
        }

        if ($searchStatus === NULL || $searchStatus == 'anything') {
            $anything = 'selected ';
        } elseif ($searchStatus == 'ok') {
            $ok = ' selected';
        } elseif ($searchStatus == 'disabled') {
            $suspended = ' selected';
        } elseif (($searchStatus == 'error')) {
            $error = ' selected';
        } else {
            showBadRequestErrorPage();
        }

        $tpl->assign('SEARCH_VALUE', $searchValue !== NULL ? toHtml($searchValue, 'htmlAttr') : '');
    }

    $tpl->assign([
        # search_field select
        'CLIENT_NONE_SELECTED'          => $none,
        'CLIENT_DOMAIN_NAME_SELECTED'   => $domain,
        'CLIENT_FIRST_NAME_SELECTED'    => $firstname,
        'CLIENT_LAST_NAME_SELECTED'     => $lastname,
        'CLIENT_COMPANY_SELECTED'       => $company,
        'CLIENT_CITY_SELECTED'          => $city,
        'CLIENT_STATE_SELECTED'         => $state,
        'CLIENT_COUNTRY_SELECTED'       => $country,
        'CLIENT_RESELLER_NAME_SELECTED' => $resellerName,
        # search_status select
        'CLIENT_ANYTHING_SELECTED'      => $anything,
        'CLIENT_OK_SELECTED'            => $ok,
        'CLIENT_DISABLED_SELECTED'      => $suspended,
        'CLIENT_ERROR_SELECTED'         => $error
    ]);
}

/**
 * Generates user domain_aliases_list
 *
 * @param TemplateEngine $tpl
 * @param int $domainId Domain unique identifier
 * @return void
 */
function generateDomainAliasesList(TemplateEngine $tpl, $domainId)
{
    $tpl->assign('CLIENT_DOMAIN_ALIAS_BLK', '');

    if (!isset($_SESSION['client_domain_aliases_switch']) || $_SESSION['client_domain_aliases_switch'] != 'show') {
        return;
    }

    $stmt = execQuery('SELECT alias_name FROM domain_aliases WHERE domain_id = ? ORDER BY alias_name ASC', [$domainId]);

    if (!$stmt->rowCount()) {
        return;
    }

    while ($row = $stmt->fetch()) {
        $tpl->assign([
            'CLIENT_DOMAIN_ALIAS_URL' => toHtml($row['alias_name'], 'htmlAttr'),
            'CLIENT_DOMAIN_ALIAS'     => toHtml(decodeIdna($row['alias_name']))
        ]);
        $tpl->parse('CLIENT_DOMAIN_ALIAS_BLK', '.client_domain_alias_blk');
    }
}

/**
 * Generate user list
 *
 * @param TemplateEngine $tpl
 * @return void
 */
function generateCustomersList(TemplateEngine $tpl)
{
    $cfg = Registry::get('config');

    if (!empty($_POST)) {
        if (!isset($_POST['search_status']) || !isset($_POST['search_field']) || !isset($_POST['client_domain_aliases_switch'])
            || !in_array($_POST['client_domain_aliases_switch'], ['show', 'hide'])
        ) {
            showBadRequestErrorPage();
        }

        $_SESSION['client_domain_aliases_switch'] = cleanInput($_POST['client_domain_aliases_switch']);
        $_SESSION['search_field'] = cleanInput($_POST['search_field']);
        $_SESSION['search_value'] = isset($_POST['search_value']) ? cleanInput($_POST['search_value']) : '';
        $_SESSION['search_status'] = cleanInput($_POST['search_status']);
    } elseif (!isset($_GET['psi'])) {
        unset($_SESSION['search_field'], $_SESSION['search_value'], $_SESSION['search_status']);
    }

    $sLimit = isset($_GET['psi']) ? intval($_GET['psi']) : 0;
    $eLimit = intval($cfg['DOMAIN_ROWS_PER_PAGE']);

    if (!empty($_POST)) {
        list($cQuery, $sQuery) = getSearchUserQueries(
            $sLimit, $eLimit, $_SESSION['search_field'], $_SESSION['search_value'], $_SESSION['search_status']
        );
        generateSearchUserFields($tpl, $_SESSION['search_field'], $_SESSION['search_value'], $_SESSION['search_status']);
    } else {
        list($cQuery, $sQuery) = getSearchUserQueries($sLimit, $eLimit);
        generateSearchUserFields($tpl);
    }

    if (isset($_SESSION['client_domain_aliases_switch'])) {
        $tpl->assign([
            'CLIENT_DOMAIN_ALIASES_SWITCH_VALUE'                              => $_SESSION['client_domain_aliases_switch'],
            $_SESSION['client_domain_aliases_switch'] == 'show'
                ? 'CLIENT_DOMAIN_ALIASES_SHOW' : 'CLIENT_DOMAIN_ALIASES_HIDE' => ''
        ]);
    } else {
        $tpl->assign([
            'CLIENT_DOMAIN_ALIASES_SWITCH_VALUE' => 'hide',
            'CLIENT_DOMAIN_ALIASES_HIDE'         => ''
        ]);
    }

    $rowCount = executeQuery($cQuery)->fetchColumn();
    if ($rowCount < 1) {
        if (!empty($_POST)) {
            $tpl->assign([
                'CLIENT_DOMAIN_ALIASES_SWITCH' => '',
                'CLIENT_LIST'                  => '',
            ]);
        } else {
            $tpl->assign([
                'CLIENT_SEARCH_FORM' => '',
                'CLIENT_LIST'        => ''
            ]);
        }
        return;
    }

    if ($sLimit == 0) {
        $tpl->assign('CLIENT_SCROLL_PREV', '');
    } else {
        $prevSi = $sLimit - $eLimit;
        $tpl->assign([
            'CLIENT_SCROLL_PREV_GRAY' => '',
            'CLIENT_PREV_PSI'         => $prevSi > 0 ? $prevSi : 0
        ]);
    }

    $nextSi = $sLimit + $eLimit;
    if ($nextSi + 1 > $rowCount) {
        $tpl->assign('CLIENT_SCROLL_NEXT', '');
    } else {
        $tpl->assign([
            'CLIENT_SCROLL_NEXT_GRAY' => '',
            'CLIENT_NEXT_PSI'         => $nextSi
        ]);
    }

    $tpl->assign('CLIENT_MESSAGE', '');
    $stmt = executeQuery($sQuery);

    while ($row = $stmt->fetch()) {
        $statusOk = true;
        $statusTxt = $statusTooltip = humanizeDomainStatus(
            $row['admin_status'] != 'ok' ? $row['admin_status'] : $row['domain_status']
        );

        if ($row['admin_status'] == 'ok' && $row['domain_status'] == 'ok') {
            $class = 'i_ok';
            $statusTooltip = tr('Click to suspend this customer account.');
        } elseif ($row['domain_status'] == 'disabled') {
            $class = 'i_disabled';
            $statusTooltip = tr('Click to unsuspend this customer account.');
        } elseif (in_array($row['admin_status'], ['tochange', 'tochangepwd'])
            || in_array($row['domain_status'], ['toadd', 'tochange', 'torestore', 'toenable', 'todisable', 'todelete'])
        ) {
            $class = 'i_reload';
            $statusOk = false;
        } else {
            $class = 'i_error';
            $statusTooltip = tr('An unexpected error occurred.');
            $statusOk = false;
        }

        $tpl->assign([
            'CLIENT_STATUS_CLASS'      => $class,
            'TR_CLIENT_STATUS_TOOLTIP' => $statusTooltip,
            'TR_CLIENT_STATUS'         => $statusTxt,
            'CLIENT_USERNAME'          => toHtml(decodeIdna($row['domain_name']), 'htmlAttr'),
            'CLIENT_DOMAIN_ID'         => $row['domain_id'],
            'CLIENT_ID'                => $row['admin_id'],
            'CLIENT_CREATED_ON'        => toHtml($row['domain_created'] == 0 ? tr('N/A') : date($cfg['DATE_FORMAT'], $row['domain_created'])),
            'CLIENT_CREATED_BY'        => toHtml($row['reseller_name']),
            'CLIENT_EXPIRY_DATE'       => toHtml(
                $row['domain_expires'] != 0 ? date(Registry::get('config')['DATE_FORMAT'], $row['domain_expires']) : tr('∞')
            )
        ]);

        if ($statusOk) {
            $tpl->assign([
                'CLIENT_DOMAIN_STATUS_NOT_OK' => '',
                'CLIENT_DOMAIN_URL'           => toHtml($row['domain_name'], 'htmlAttr')
            ]);
            $tpl->parse('CLIENT_DOMAIN_STATUS_OK', 'client_domain_status_ok');
            $tpl->parse('CLIENT_RESTRICTED_LINKS', 'client_restricted_links');
        } else {
            $tpl->assign([
                'CLIENT_DOMAIN_STATUS_OK' => '',
                'CLIENT_RESTRICTED_LINKS' => ''
            ]);
            $tpl->parse('CLIENT_DOMAIN_STATUS_NOT_OK', 'client_domain_status_not_ok');
        }

        generateDomainAliasesList($tpl, $row['domain_id']);
        $tpl->parse('CLIENT_ITEM', '.client_item');
    }
}

/**
 * Generate manage users page
 *
 * @param  TemplateEngine $tpl
 * @return void
 */
function get_admin_manage_users(TemplateEngine $tpl)
{
    generateAdministratorsList($tpl);
    generateResellersList($tpl);
    generateCustomersList($tpl);
}

// Reseller

/**
 * Generate IP addresses list for the given reseller
 *
 * @param TemplateEngine $tpl
 * @param int $resellerId Reseller unique identifier
 * @param array $sips Selected IP addresses (identifiers)
 */
function generateResellerIpsList(TemplateEngine $tpl, $resellerId, array $sips)
{
    $ips = execQuery(
        "
            SELECT t2.ip_id, t2.ip_number
            FROM reseller_props AS t1
            JOIN server_ips AS t2 ON(FIND_IN_SET(t2.ip_id, t1.reseller_ips) AND t2.ip_status = 'ok')
            WHERE t1.reseller_id = ?
            ORDER BY LENGTH(t2.ip_number), t2.ip_number
        ",
        [$resellerId]
    )->fetchAll();

    foreach ($ips as $ip) {
        $tpl->assign([
            'IP_NUM'      => toHtml($ip['ip_number'] == '0.0.0.0' ? tr('Any') : $ip['ip_number'], 'htmlAttr'),
            'IP_VALUE'    => toHtml($ip['ip_id']),
            'IP_SELECTED' => in_array($ip['ip_id'], $sips) ? ' selected' : ''
        ]);
        $tpl->parse('IP_ENTRY', '.ip_entry');
    }
}

// Client

/**
 * Generate IP addresses list for the given client
 *
 * @param TemplateEngine $tpl
 * @param int $clientId Client unique identifier
 * @param array $sips Selected IP addresses (identifiers)
 */
function generateClientIpsList($tpl, $clientId, array $sips)
{
    $ips = execQuery(
        "   SELECT t2.ip_id, t2.ip_number
            FROM domain AS t1
            JOIN server_ips AS t2 ON(FIND_IN_SET(t2.ip_id, t1.domain_client_ips))
            WHERE t1.reseller_id = ?
            ORDER BY LENGTH(t2.ip_number), t2.ip_number
        ",
        [$clientId]
    )->fetchAll();

    foreach ($ips as $ip) {
        $tpl->assign([
            'IP_NUM'      => toHtml($ip['ip_number'] == '0.0.0.0' ? tr('Any') : $ip['ip_number'], 'htmlAttr'),
            'IP_VALUE'    => toHtml($ip['ip_id']),
            'IP_SELECTED' => in_array($ip['ip_id'], $sips) ? ' selected' : ''
        ]);
        $tpl->parse('IP_ENTRY', '.ip_entry');
    }
}

// Common

/**
 * Returns translation for jQuery DataTables plugin.
 *
 * @param bool $json Does the data must be encoded to JSON?
 * @param array $override Allow to override or add plugin translation
 * @return string|array
 */
function getDataTablesPluginTranslations($json = true, array $override = [])
{
    $tr = [
        'sLengthMenu'  => tr(
            'Show %s records per page',
            '
                <select>
                <option value="10">10</option>
                <option value="15">15</option>
                <option value="20">20</option>
                <option value="50">50</option>
                <option value="100">100</option>
                </select>
            '
        ),
        //'sLengthMenu' => tr('Show %s records per page', '_MENU_'),
        'zeroRecords'  => tr('Nothing found - sorry'),
        'info'         => tr('Showing %s to %s of %s records', '_START_', '_END_', '_TOTAL_'),
        'infoEmpty'    => tr('Showing 0 to 0 of 0 records'),
        'infoFiltered' => tr('(filtered from %s total records)', '_MAX_'),
        'search'       => tr('Search'),
        'paginate'     => ['previous' => tr('Previous'), 'next' => tr('Next')],
        'processing'   => tr('Loading data...')
    ];

    if (!empty($override)) {
        $tr = array_merge($tr, $override);
    }

    return ($json) ? json_encode($tr) : $tr;
}

/**
 * Show the given error page
 *
 * @param int $code Code of error page to show (400, 403 or 404)
 * @throws iMSCPException
 * @return void
 */
function showErrorPage($code)
{
    switch ($code) {
        case 400:
            $message = 'Bad Request';
            break;
        case 403:
            $message = 'Forbidden';
            break;
        case 404:
            $message = 'Not Found';
            break;
        case 500:
            $message = 'Internal Server Error';
            break;
        default:
            throw new iMSCPException(500, 'Unknown error page');
    }

    header("Status: $code $message");

    if (isset($_SERVER['HTTP_ACCEPT'])) {
        if (strpos($_SERVER['HTTP_ACCEPT'], 'application/json') !== false) {
            header("Content-type: application/json");
            exit(json_encode([
                'code'    => $code,
                'message' => $message
            ]));
        }

        if (strpos($_SERVER['HTTP_ACCEPT'], 'application/xmls') !== false) {
            header("Content-type: text/xml;charset=utf-8");
            exit(<<<EOF
<?xml version="1.0" encoding="utf-8"?>
<response>
    <code>$code</code>
    <message>$message</message>
</response>
EOF
            );
        }
    }

    if (!isXhr()) {
        include(Registry::get('config')['FRONTEND_ROOT_DIR'] . "/public/errordocs/$code.html");
    }

    exit($code);
}

/**
 * Show 400 error page
 *
 * @return void
 */
function showBadRequestErrorPage()
{
    showErrorPage(400);
}

/**
 * Show 404 error page
 *
 * @return void
 */
function showForbiddenErrorPage()
{
    showErrorPage(403);
}

/**
 * Show 404 error page
 *
 * @return void
 */
function showNotFoundErrorPage()
{
    showErrorPage(404);
}

/**
 * Show 404 error page
 *
 * @return void
 */
function showInternalServerError()
{
    showErrorPage(500);
}